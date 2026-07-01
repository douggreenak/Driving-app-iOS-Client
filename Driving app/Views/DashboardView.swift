import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DriveTrip.date, order: .reverse) private var allTrips: [DriveTrip]
    @Query private var scheduled: [ScheduledDrive]
    @Query private var settingsList: [UserSettings]
    @Query private var vehicles: [Vehicle]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]

    private var fuelPrice: Double { settingsList.first?.fuelPricePerGallon ?? 3.75 }

    @State private var gas: APIStats?
    @State private var lastUpdated: Date?
    @State private var isRefreshing = false
    @State private var showingSettings = false
    @State private var showingEditLayout = false

    // Persisted dashboard layout: the widget order and which widgets are hidden.
    @AppStorage("dashboard.order") private var savedOrder = ""
    @AppStorage("dashboard.hidden") private var savedHidden = ""

    private var orderedWidgets: [DashboardWidget] { DashboardWidget.parseOrder(savedOrder) }
    private var hiddenWidgets: Set<DashboardWidget> { DashboardWidget.parseHidden(savedHidden) }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private var nextDrive: ScheduledDrive? {
        let now = Date.now
        // Surface whichever drive is most imminent by its Up Next occurrence — including a drive
        // that's *overdue to leave* (delayed) but hasn't been started. Ranking by absolute distance
        // to now means an overdue drive wins over a later on-time one, so a late drive is never
        // hidden behind the next on-time trip.
        return scheduled
            .filter { $0.isEnabled && !$0.isCanceled }
            .compactMap { drive in drive.upNextDeparture(now: now).map { (drive, $0) } }
            .min { abs($0.1.timeIntervalSince(now)) < abs($1.1.timeIntervalSince(now)) }?
            .0
    }

    var body: some View {
        NavigationStack {
            ScrollView { scrollContent }
                .background(.black)
                .navigationTitle(greeting)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingEditLayout = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Edit dashboard layout")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingSettings = true } label: { Image(systemName: "gearshape.fill") }
                    }
                }
                .sheet(isPresented: $showingSettings) { SettingsView() }
                .sheet(isPresented: $showingEditLayout) { DashboardLayoutEditor() }
                .refreshable { await loadGas() }
                .task { await loadGas() }
                .task {
                    // Push local trips up (incl. any unsynced) and backfill payer onto historical
                    // trips so all current app data reaches the server.
                    await TripStore.syncPending(context: context)
                    await TripStore.backfillPaidBy(context: context)
                }
                .task(id: watchSyncKey) { broadcastToWatch() }
        }
    }

    /// Changes whenever the drives/trips the watch mirrors change, so we re-push then.
    private var watchSyncKey: String { "\(scheduled.count)-\(allTrips.count)" }

    /// Mirror upcoming drives + headline stats to the Apple Watch companion.
    private func broadcastToWatch() {
        #if canImport(WatchConnectivity) && os(iOS)
        let now = Date.now
        let fillUps = Dictionary(vehicles.compactMap { v in v.lastFilledUp.map { (v.name, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        let stats = DrivingStats(trips: allTrips, fillUps: fillUps)
        let drives = scheduled
            .filter { $0.isEnabled && !$0.isCanceled }
            .compactMap { d -> (WatchSyncPayload.Drive, Date)? in
                guard let dep = d.upNextDeparture(now: now) else { return nil }
                return (WatchSyncPayload.Drive(
                    id: d.id.uuidString, title: d.title, departure: dep,
                    endName: PlaceNamer.name(for: d.endCoordinate, fallback: d.endAddress, in: savedPlaces),
                    paidByParents: d.paidBy == .parents), dep)
            }
            .sorted { abs($0.1.timeIntervalSince(now)) < abs($1.1.timeIntervalSince(now)) }
            .prefix(10)
            .map(\.0)
        let payload = WatchSyncPayload(
            drives: Array(drives),
            stats: .init(totalMiles: stats.totalMiles, totalDrives: stats.driveCount, totalGallons: stats.totalGallons))
        PhoneWatchConnectivity.shared.sync(payload)
        #endif
    }

    private var scrollContent: some View {
        // Compute the (potentially large) stats roll-up once per render instead of once per section.
        let fillUps = Dictionary(vehicles.compactMap { v in v.lastFilledUp.map { (v.name, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        let stats = DrivingStats(trips: allTrips, fillUps: fillUps)
        let widgets = orderedWidgets.filter { !hiddenWidgets.contains($0) && isAvailable($0, stats) }
        return VStack(spacing: 20) {
            if allTrips.isEmpty && nextDrive == nil { emptyState }
            ForEach(widgets, id: \.self) { widget in
                widgetView(widget, stats: stats)
            }
            LastUpdatedBanner(lastUpdated: lastUpdated, isRefreshing: isRefreshing)
        }
        .padding(.horizontal).padding(.bottom, 20)
    }

    /// Whether a widget has data to show right now (independent of the user hiding it).
    private func isAvailable(_ widget: DashboardWidget, _ stats: DrivingStats) -> Bool {
        switch widget {
        case .upNext:   return nextDrive != nil
        case .hero, .paidBy, .records: return !allTrips.isEmpty
        case .byCar:    return !stats.byCar.isEmpty
        case .monthly:  return stats.monthly.count > 1
        case .category: return !stats.byCategory.isEmpty
        case .onTime:   return stats.scheduledCount > 0
        case .gas:      return true
        case .recent:   return allTrips.first != nil
        }
    }

    @ViewBuilder
    private func widgetView(_ widget: DashboardWidget, stats: DrivingStats) -> some View {
        switch widget {
        case .upNext:   if let drive = nextDrive { upcomingCard(drive) }
        case .hero:     heroStats(stats)
        case .paidBy:   paidBySection(stats)
        case .records:  recordsStrip(stats)
        case .byCar:    byCarSection(stats)
        case .monthly:  monthlySection(stats)
        case .category: categorySection(stats)
        case .onTime:   onTimeSection(stats)
        case .gas:      gasSection
        case .recent:   if let trip = allTrips.first { recentTripSection(trip) }
        }
    }

    // MARK: - Hero totals (Flighty-style)

    private func heroStats(_ stats: DrivingStats) -> some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            HeroTile(icon: "road.lanes", tint: .blue, value: format(stats.totalMiles), unit: "miles driven",
                     sub: String(format: "%.0f mi avg / trip", stats.avgDriveMiles))
            HeroTile(icon: "clock.fill", tint: .orange, value: DrivingStats.duration(stats.totalSeconds), unit: "time driving",
                     sub: String(format: "%.0f mph avg", stats.avgMph))
            HeroTile(icon: "fuelpump.fill", tint: .green, value: String(format: "%.1f", stats.totalGallons), unit: "gal burned",
                     sub: stats.avgMpg > 0 ? String(format: "%.0f MPG effective", stats.avgMpg) : "—")
            HeroTile(icon: "flag.checkered", tint: .purple, value: "\(stats.driveCount)", unit: stats.driveCount == 1 ? "drive logged" : "drives logged",
                     sub: stats.byCar.count.things("car"))
        }
    }

    // MARK: - Who's paying (the core feature)

    private func paidBySection(_ stats: DrivingStats) -> some View {
        let price = fuelPrice
        let total = max(stats.totalCost(pricePerGallon: price), 0.01)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Who's paying for gas", "dollarsign.circle.fill")
            ForEach(PaidBy.allCases, id: \.self) { payer in
                let cost = stats.cost(for: payer, pricePerGallon: price)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(payer.label, systemImage: payer.icon)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(payer.tint)
                        Spacer()
                        Text(cost, format: .currency(code: "USD"))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                    }
                    GeometryReader { geo in
                        Capsule().fill(payer.tint.gradient)
                            .frame(width: max(6, geo.size.width * CGFloat(cost / total)), height: 8)
                    }
                    .frame(height: 8)
                    Text("\(stats.drives(for: payer)) drives · \(format(stats.miles(for: payer))) mi · \(String(format: "%.1f", stats.gallons(for: payer))) gal")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Estimated at \(fuelPrice, format: .currency(code: "USD"))/gal — set the price in Settings.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Records

    private func recordsStrip(_ stats: DrivingStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Records", "trophy.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(stats.records, id: \.title) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: r.icon).font(.title3).foregroundStyle(.yellow)
                            Text(r.value).font(.system(.title3, design: .rounded, weight: .bold))
                            Text(r.title).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 110, alignment: .leading)
                        .padding()
                        .background(Color(.systemGray6), in: .rect(cornerRadius: 14))
                    }
                }
            }
        }
    }

    // MARK: - Time spent in different cars

    private func byCarSection(_ stats: DrivingStats) -> some View {
        let maxSeconds = stats.byCar.map(\.seconds).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Time in each car", "car.2.fill")
            ForEach(stats.byCar) { car in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(car.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(DrivingStats.duration(car.seconds)) · \(format(car.miles)) mi")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill(.blue.gradient)
                            .frame(width: max(6, geo.size.width * CGFloat(car.seconds) / CGFloat(maxSeconds)), height: 8)
                    }
                    .frame(height: 8)
                    Text("\(car.count) drive\(car.count == 1 ? "" : "s") · \(String(format: "%.1f", car.gallons)) gal")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Monthly activity

    private func monthlySection(_ stats: DrivingStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Miles per month", "chart.bar.fill")
            Chart(stats.monthly) { m in
                BarMark(x: .value("month", m.monthStart, unit: .month), y: .value("miles", m.miles))
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
            .frame(height: 150)
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - By category

    private func categorySection(_ stats: DrivingStats) -> some View {
        let maxMiles = stats.byCategory.map(\.miles).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("By category", "square.grid.2x2.fill")
            ForEach(stats.byCategory) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.category.icon).foregroundStyle(.blue).frame(width: 22)
                    Text(c.category.label).font(.subheadline)
                    Spacer()
                    Text("\(format(c.miles)) mi").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule().fill(.blue.opacity(0.7))
                        .frame(width: max(6, geo.size.width * CGFloat(c.miles / maxMiles)), height: 6)
                }
                .frame(height: 6)
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - On-time performance

    private func onTimeSection(_ stats: DrivingStats) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.green.opacity(0.2), lineWidth: 8)
                Circle().trim(from: 0, to: stats.onTimePercent / 100)
                    .stroke(.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(stats.onTimePercent))%").font(.headline.weight(.bold))
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("On-time performance").font(.subheadline.weight(.semibold))
                Text("\(stats.onTimeCount) of \(stats.scheduledCount.things("scheduled drive")) on time")
                    .font(.caption).foregroundStyle(.secondary)
                if let avg = stats.avgDelaySeconds {
                    Text(avg > 60 ? "Avg \(Fmt.duration(avg)) late" : avg < -60 ? "Avg \(Fmt.duration(-avg)) early" : "On schedule")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(avg > 60 ? .orange : .green)
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Gas (network, cached + freshness)

    private var gasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Gas spending", "dollarsign.circle.fill")
            if let g = gas {
                Text(g.totalSpent, format: .currency(code: "USD"))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                if g.totalSpent > 0 {
                    BarRow(label: "Paid by Me", amount: g.selfPaid, total: g.totalSpent, color: .blue)
                    BarRow(label: "Paid by Parents", amount: g.parentsPaid, total: g.totalSpent, color: .green)
                } else {
                    Text("No fuel purchases logged yet").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if isRefreshing {
                HStack(spacing: 10) { ProgressView(); Text("Loading gas log…").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                Text("Gas log unavailable").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Upcoming / latest / empty

    private func upcomingCard(_ drive: ScheduledDrive) -> some View {
        NavigationLink {
            ScheduledDriveDetailView(drive: drive)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Up Next", systemImage: "calendar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    StatusChip(status: .occurrence(departure: drive.statusReferenceDeparture(),
                                                   scheduledArrival: drive.targetArrival(),
                                                   travelSeconds: drive.estimatedTravelTime,
                                                   isCanceled: drive.isCanceled,
                                                   startedAt: drive.lastStartedAt), compact: true)
                }
                Text(drive.title).font(.title3.weight(.bold))
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(.blue)
                    Text(drive.statusReferenceDeparture(), format: .dateTime.weekday().hour().minute()).font(.subheadline.weight(.medium))
                    Text(TripStatus.countdown(to: drive.statusReferenceDeparture())).font(.caption.weight(.semibold)).foregroundStyle(.blue)
                }
                Text("\(PlaceNamer.name(for: drive.startCoordinate, fallback: drive.startAddress, in: savedPlaces)) → \(PlaceNamer.name(for: drive.endCoordinate, fallback: drive.endAddress, in: savedPlaces))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.blue.opacity(0.12), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.blue.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView("No drives yet", systemImage: "car.fill",
            description: Text("Track a drive and your stats will show up here."))
            .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    private func recentTripSection(_ trip: DriveTrip) -> some View {
        NavigationLink {
            TripDetailView(trip: trip)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Latest Trip").font(.headline)
                    Spacer()
                    if trip.delaySeconds != nil {
                        StatusChip(status: .forTrip(delaySeconds: trip.delaySeconds), compact: true)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PlaceNamer.name(for: trip.startCoordinate, fallback: trip.startAddress, in: savedPlaces)).font(.subheadline.weight(.medium)).lineLimit(1)
                        Label(PlaceNamer.name(for: trip.endCoordinate, fallback: trip.endAddress, in: savedPlaces), systemImage: "arrow.right").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(String(format: "%.1f mi", trip.distance)).font(.subheadline.weight(.semibold))
                        Text(trip.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding().background(Color(.systemGray6), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ miles: Double) -> String {
        miles >= 1000 ? String(format: "%.0f", miles) : String(format: "%.1f", miles)
    }

    // MARK: - Gas load (stale-while-revalidate + freshness)

    private func loadGas() async {
        if gas == nil, let cached = Self.cachedGas() {
            gas = cached.stats
            lastUpdated = cached.date
        }
        isRefreshing = true
        do {
            let fresh = try await APIClient.fetchStats()
            gas = fresh
            lastUpdated = .now
            Self.cacheGas(fresh, at: .now)
        } catch { /* keep cached */ }
        isRefreshing = false
    }

    private static let gasCacheKey = "dashboard.cachedGas"
    private static let gasDateKey = "dashboard.cachedGasDate"

    private static func cachedGas() -> (stats: APIStats, date: Date)? {
        guard let data = UserDefaults.standard.data(forKey: gasCacheKey),
              let stats = try? JSONDecoder().decode(APIStats.self, from: data) else { return nil }
        let date = UserDefaults.standard.object(forKey: gasDateKey) as? Date ?? .now
        return (stats, date)
    }

    private static func cacheGas(_ stats: APIStats, at date: Date) {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: gasCacheKey)
            UserDefaults.standard.set(date, forKey: gasDateKey)
        }
    }
}

private struct HeroTile: View {
    let icon: String, tint: Color, value: String, unit: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title3.weight(.medium)).foregroundStyle(tint)
            Text(value).font(.system(.title, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 14))
    }
}

private struct BarRow: View {
    let label: String, amount: Double, total: Double, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(amount, format: .currency(code: "USD")).font(.subheadline.weight(.semibold))
            }
            ProgressView(value: total > 0 ? amount / total : 0).tint(color)
        }
    }
}

// MARK: - Editable dashboard layout

/// A rearrangeable/hideable section on the dashboard. Declaration order is the default layout.
enum DashboardWidget: String, CaseIterable, Identifiable {
    case upNext, hero, paidBy, records, byCar, monthly, category, onTime, gas, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upNext:   "Up Next"
        case .hero:     "Totals"
        case .paidBy:   "Who's Paying"
        case .records:  "Records"
        case .byCar:    "Time in Each Car"
        case .monthly:  "Miles Per Month"
        case .category: "By Category"
        case .onTime:   "On-Time Performance"
        case .gas:      "Gas Spending"
        case .recent:   "Latest Trip"
        }
    }

    var icon: String {
        switch self {
        case .upNext:   "calendar"
        case .hero:     "chart.bar.fill"
        case .paidBy:   "dollarsign.circle.fill"
        case .records:  "trophy.fill"
        case .byCar:    "car.fill"
        case .monthly:  "chart.xyaxis.line"
        case .category: "tag.fill"
        case .onTime:   "clock.fill"
        case .gas:      "fuelpump.fill"
        case .recent:   "map.fill"
        }
    }

    /// Parse the saved order, appending any widgets missing from it (e.g. added in a newer build)
    /// at the end so new sections still appear.
    static func parseOrder(_ raw: String) -> [DashboardWidget] {
        let saved = raw.split(separator: ",").compactMap { DashboardWidget(rawValue: String($0)) }
        return saved + allCases.filter { !saved.contains($0) }
    }

    static func parseHidden(_ raw: String) -> Set<DashboardWidget> {
        Set(raw.split(separator: ",").compactMap { DashboardWidget(rawValue: String($0)) })
    }
}

/// Reorder (drag) and show/hide (eye) the dashboard's widgets. Changes persist immediately.
struct DashboardLayoutEditor: View {
    @AppStorage("dashboard.order") private var savedOrder = ""
    @AppStorage("dashboard.hidden") private var savedHidden = ""
    @Environment(\.dismiss) private var dismiss

    @State private var order: [DashboardWidget] = []
    @State private var hidden: Set<DashboardWidget> = []

    var body: some View {
        NavigationStack {
            List {
                Text("Drag to reorder · tap the eye to show or hide")
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                ForEach(order) { widget in
                    row(widget)
                }
                .onMove { indices, dest in
                    order.move(fromOffsets: indices, toOffset: dest)
                    persist()
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                order = DashboardWidget.parseOrder(savedOrder)
                hidden = DashboardWidget.parseHidden(savedHidden)
            }
        }
    }

    @ViewBuilder
    private func row(_ widget: DashboardWidget) -> some View {
        let isHidden = hidden.contains(widget)
        HStack(spacing: 12) {
            Image(systemName: widget.icon).foregroundStyle(.blue).frame(width: 24)
            Text(widget.title)
            Spacer()
            Button {
                Haptics.selection()
                if isHidden { hidden.remove(widget) } else { hidden.insert(widget) }
                persist()
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(isHidden ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
        }
        .opacity(isHidden ? 0.5 : 1)
    }

    private func persist() {
        savedOrder = order.map(\.rawValue).joined(separator: ",")
        savedHidden = hidden.map(\.rawValue).joined(separator: ",")
    }
}
