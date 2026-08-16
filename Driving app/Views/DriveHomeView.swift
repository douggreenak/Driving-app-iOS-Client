import SwiftUI
import SwiftData
import CoreLocation
import MapKit

/// The app's home: a single unified surface that merges live tracking with the schedule. A warm
/// greeting, the next drive promoted as a hero card, one prominent "Start a Drive" action that opens
/// live tracking full-screen, and below it the Flightradar24-style departures board — every
/// occurrence of every (repeating) drive as its own row. Swipe to cancel or delete; tap for detail.
struct DriveHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(ActiveDriveController.self) private var activeDrive
    @Environment(\.tabActivityToken) private var activityToken
    @Query private var drives: [ScheduledDrive]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query private var settingsList: [UserSettings]

    @State private var showingNew = false
    @State private var showingPredict = false
    @State private var showingSettings = false
    @State private var showingAddPlace = false
    @State private var pendingDelete: DriveOccurrence?
    @State private var recovered: DriveLogger.Recovered?

    // "Go to" — one-tap ad-hoc navigation to a saved place with a computed ETA and on-time grading.
    @State private var goToLoadingPlace: UUID?
    @State private var goToLocator = CurrentLocationProvider()

    /// How many days of occurrences are currently materialized. Grows in batches as the user
    /// scrolls, so a repeating drive's series is effectively infinite instead of stopping early.
    @State private var horizonDays = 21
    private let pageDays = 21

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    /// The single most-imminent occurrence, promoted to the hero card. Ranking by absolute distance
    /// to now means an overdue-but-unstarted drive wins over a later on-time one, so a late drive is
    /// never hidden. This exact occurrence is skipped in the board below to avoid showing it twice.
    private var upNext: (drive: ScheduledDrive, departure: Date)? {
        let now = Date.now
        return drives
            .filter { $0.isEnabled }
            .compactMap { d in d.upNextDeparture(now: now).map { (d, $0) } }
            .min { abs($0.1.timeIntervalSince(now)) < abs($1.1.timeIntervalSince(now)) }
    }

    /// Is there anything past the current horizon worth loading? Repeating drives generate forever;
    /// a one-time drive only extends the list if it departs beyond the horizon.
    private var hasMoreToLoad: Bool {
        if drives.contains(where: { $0.repeatRule != .none }) { return true }
        let cal = Calendar.current
        let horizonEnd = cal.date(byAdding: .day, value: horizonDays, to: cal.startOfDay(for: .now)) ?? .now
        return drives.contains { $0.repeatRule == .none && $0.departure > horizonEnd }
    }

    private func loadMore() {
        guard hasMoreToLoad else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            horizonDays += pageDays
        }
    }

    /// All today/upcoming occurrences across all drives, grouped by day — with the promoted Up Next
    /// occurrence removed so it doesn't appear both in the hero and the board.
    private var grouped: [(day: Date, items: [DriveOccurrence])] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: horizonDays, to: start) ?? start
        let promoted = upNext
        var all: [DriveOccurrence] = []
        for drive in drives {
            for dep in drive.occurrences(in: start...end) {
                if let promoted, promoted.drive.id == drive.id, promoted.departure == dep { continue }
                let occ = DriveOccurrence(drive: drive, departure: dep,
                                          arrival: dep.addingTimeInterval(drive.arrivalBudget))
                if occ.isCompleted || occ.isStaleDeparted { continue }
                all.append(occ)
            }
        }
        let dict = Dictionary(grouping: all) { cal.startOfDay(for: $0.departure) }
        return dict.keys.sorted().map { day in
            (day, dict[day]!.sorted { $0.departure < $1.departure })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                homeSection
                goToSection
                boardSections
            }
            .listStyle(.plain)
            .background(.black)
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showingNew = true } label: { Label("Schedule a Drive", systemImage: "calendar.badge.plus") }
                        Button { showingPredict = true } label: { Label("Predict a Route", systemImage: "dollarsign.arrow.circlepath") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $showingNew) { NewScheduledDriveView() }
            .sheet(isPresented: $showingPredict) { RoutePredictView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingAddPlace) {
                AddBookmarkView(nextOrder: (savedPlaces.map(\.sortOrder).max() ?? -1) + 1)
            }
            .confirmationDialog("Delete this scheduled drive?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                if let occ = pendingDelete {
                    if occ.drive.repeatRule != .none {
                        Button("Delete Just This One", role: .destructive) { deleteOccurrence(occ) }
                        Button("Delete All Future Drives", role: .destructive) { deleteSeries(occ.drive) }
                    } else {
                        Button("Delete Drive", role: .destructive) { deleteSeries(occ.drive) }
                    }
                }
            } message: {
                let repeats = (pendingDelete?.drive.repeatRule ?? .none) != .none
                Text(repeats
                     ? "This drive repeats. Delete only this occurrence, or all future occurrences?"
                     : "This removes the scheduled drive.")
            }
            .refreshable {
                await TripStore.syncPending(context: context)
                await ScheduledDriveStore.sync(context: context)
            }
            // `.task(id:)` so a schedule edited elsewhere (web dashboard, another device) is pulled
            // in on every revisit to this tab / app-foreground, not just the first time it's shown.
            .task(id: activityToken) { await ScheduledDriveStore.sync(context: context) }
            .task { recovered = LocationTracker.recoverableSession() }
        }
    }

    // MARK: - Home section (recovery · up next · start)

    @ViewBuilder
    private var homeSection: some View {
        Section {
            if recovered != nil {
                recoveryBanner
            }
            if let up = upNext {
                upNextCard(up.drive, departure: up.departure)
            }
            startButton
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private var recoveryBanner: some View {
        Button { activeDrive.adoptRecovering() } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title2).foregroundStyle(Color.statusDelay)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unsaved drive").font(.subheadline.weight(.semibold))
                    Text("Tap to resume, save, or discard").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.statusDelay.opacity(0.14), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.statusDelay.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func upNextCard(_ drive: ScheduledDrive, departure: Date) -> some View {
        let arrival = departure.addingTimeInterval(drive.arrivalBudget)
        return NavigationLink {
            ScheduledDriveDetailView(drive: drive, occurrence: departure)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Up Next", systemImage: "airplane.departure").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    StatusChip(status: .occurrence(departure: departure,
                                                   scheduledArrival: arrival,
                                                   travelSeconds: drive.estimatedTravelTime,
                                                   isCanceled: drive.isOccurrenceCanceled(departure),
                                                   startedAt: drive.lastStartedAt), compact: true)
                }
                Text(drive.title).font(.title3.weight(.bold))
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(.blue)
                    Text(departure, format: .dateTime.weekday().hour().minute()).font(.subheadline.weight(.medium))
                    Text(TripStatus.countdown(to: departure)).font(.caption.weight(.semibold)).foregroundStyle(.blue)
                }
                Text("\(PlaceNamer.name(for: drive.startCoordinate, fallback: drive.startAddress, in: savedPlaces)) → \(PlaceNamer.name(for: drive.endCoordinate, fallback: drive.endAddress, in: savedPlaces))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.blue.opacity(0.12), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.blue.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var startButton: some View {
        Button {
            Haptics.rigid()
            activeDrive.start(asModal: true)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "location.fill").font(.title3)
                Text("Start a Drive").font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.green.gradient, in: .capsule)
            .shadow(color: .green.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: - "Go to" (one-tap navigation to a saved place)

    /// A row of saved-place cards under a "Go to" header. Tapping one computes an ETA from the
    /// current location and starts a recorded drive to it — graded on-time against that ETA. Separate
    /// from ad-hoc "Start a Drive" and from scheduling; the drive shows up in Trips like any other.
    private var goToSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(savedPlaces) { place in goToCard(place) }
                    goToAddCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            HStack(spacing: 6) {
                Text("Go to")
                if goToLoadingPlace != nil {
                    ProgressView().controlSize(.mini)
                    Text("Finding ETA…").font(.caption2).foregroundStyle(.secondary).textCase(nil)
                }
            }
        }
    }

    private func goToCard(_ place: SavedPlace) -> some View {
        let loading = goToLoadingPlace == place.id
        return Button {
            Task { await startGoTo(place) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: place.icon)
                        .font(.headline).foregroundStyle(.blue)
                        .frame(width: 38, height: 38)
                        .background(.blue.opacity(0.15), in: .circle)
                    Spacer()
                    if loading {
                        ProgressView()
                    } else {
                        Image(systemName: "location.fill").font(.caption).foregroundStyle(.green)
                    }
                }
                Text(place.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(place.address).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(width: 150, height: 118, alignment: .leading)
            .padding(12)
            .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.blue.opacity(loading ? 0.5 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(goToLoadingPlace != nil)
    }

    private var goToAddCard: some View {
        Button { Haptics.tap(); showingAddPlace = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold)).foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.12), in: .circle)
                Text("Add Place").font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                Text(savedPlaces.isEmpty ? "Save a destination" : "Save an address")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 130, height: 118)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.blue.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
        .disabled(goToLoadingPlace != nil)
    }

    /// Fetch the current location + MapKit ETA to `place`, then start a recorded drive to it. If the
    /// ETA can't be fetched (offline / no location), the drive still starts, just ungraded.
    private func startGoTo(_ place: SavedPlace) async {
        guard goToLoadingPlace == nil else { return }
        // Never clobber an unsaved drive: a Go-to auto-starts (and the crash logger truncates the
        // active log), so if a recoverable session is pending, surface it instead of starting.
        if let rec = LocationTracker.recoverableSession() {
            Haptics.warning()
            recovered = rec
            return
        }
        Haptics.tap()
        goToLoadingPlace = place.id
        defer { goToLoadingPlace = nil }
        // Fetch the ETA as travel seconds; the departure/arrival are anchored at auto-start time so
        // they stay consistent regardless of how long this fetch takes.
        var travelSeconds: Int?
        if let here = await goToLocator.current()?.coordinate {
            let routes = await RouteMatcher.candidateRoutes(from: here, to: place.coordinate)
            if let best = routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) {
                travelSeconds = Int(best.expectedTravelTime)
            }
        }
        let target = QuickTrip(name: place.label, coordinate: place.coordinate, travelSeconds: travelSeconds,
                              paidBy: settingsList.first?.defaultPaidByRaw ?? PayerGroup.selfKey)
        activeDrive.start(goTo: target)
    }

    // MARK: - Board

    @ViewBuilder
    private var boardSections: some View {
        let groups = grouped
        if drives.isEmpty {
            emptyBoard
        } else if groups.isEmpty && upNext == nil {
            ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                description: Text("No upcoming drives. Tap + to schedule one."))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.items) { occ in
                        NavigationLink {
                            ScheduledDriveDetailView(drive: occ.drive, occurrence: occ.departure)
                        } label: {
                            DepartureRow(occ: occ)
                        }
                        .swipeActions(edge: .leading) { cancelButton(occ) }
                        .swipeActions(edge: .trailing) { deleteButton(occ) }
                    }
                } header: {
                    Text(dayLabel(group.day))
                }
            }

            if hasMoreToLoad {
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Loading more drives…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .id(horizonDays)
                .onAppear { loadMore() }
            }
        }
    }

    private var emptyBoard: some View {
        ContentUnavailableView {
            Label("No Scheduled Drives", systemImage: "calendar.badge.plus")
        } description: {
            Text("Schedule a drive and we'll predict the travel time and arrival.")
        } actions: {
            Button("Schedule a Drive") { showingNew = true }.buttonStyle(.borderedProminent)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }

    // MARK: - Swipe actions

    private func cancelButton(_ occ: DriveOccurrence) -> some View {
        // Cancel affects only this one occurrence — a repeating drive's other days keep going.
        let canceled = occ.drive.isOccurrenceCanceled(occ.departure)
        return Button {
            Haptics.selection()
            setOccurrenceCanceled(occ, !canceled)
        } label: {
            Label(canceled ? "Restore" : "Cancel",
                  systemImage: canceled ? "arrow.uturn.backward" : "xmark.octagon")
        }
        .tint(canceled ? .blue : .orange)
    }

    private func setOccurrenceCanceled(_ occ: DriveOccurrence, _ value: Bool) {
        occ.drive.setOccurrenceCanceled(occ.departure, value)
        try? occ.drive.modelContext?.save()
        Task { await ScheduledDriveStore.sync(context: context) }
    }

    private func deleteButton(_ occ: DriveOccurrence) -> some View {
        Button(role: .destructive) {
            pendingDelete = occ
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func deleteOccurrence(_ occ: DriveOccurrence) {
        Haptics.warning()
        occ.drive.skippedOccurrences.append(occ.departure)
        try? occ.drive.modelContext?.save()
        Task { await ScheduledDriveStore.sync(context: context) }
        pendingDelete = nil
    }

    private func deleteSeries(_ drive: ScheduledDrive) {
        Haptics.warning()
        let removedRemoteID = drive.remoteID
        let ctx = drive.modelContext
        ctx?.delete(drive)
        try? ctx?.save()
        Task {
            if let id = removedRemoteID { try? await APIClient.deleteScheduledDrive(id: id) }
            await ScheduledDriveStore.sync(context: context)
        }
        pendingDelete = nil
    }
}

/// One occurrence of a scheduled drive (a single departure on a specific date).
struct DriveOccurrence: Identifiable {
    let drive: ScheduledDrive
    let departure: Date
    let arrival: Date
    var id: String { "\(drive.id)-\(departure.timeIntervalSince1970)" }

    /// Was this occurrence actually driven (a recorded start in its window)?
    var isDeparted: Bool {
        guard let s = drive.lastStartedAt else { return false }
        return s >= departure.addingTimeInterval(-1800) && s <= arrival.addingTimeInterval(3 * 3600)
    }

    /// Has this occurrence arrived (tracking stopped within its window)? Completed occurrences
    /// drop off the board.
    var isCompleted: Bool {
        guard let c = drive.lastCompletedAt else { return false }
        return c >= departure.addingTimeInterval(-1800) && c <= arrival.addingTimeInterval(6 * 3600)
    }

    /// A departed occurrence now well past its window that never recorded a completion (force-quit
    /// mid-drive, or an older build's discard). Treated as finished so it drops off the board.
    var isStaleDeparted: Bool {
        isDeparted && Date() > arrival.addingTimeInterval(6 * 3600)
    }

    /// Is this specific occurrence canceled?
    var isCanceled: Bool { drive.isOccurrenceCanceled(departure) }

    var status: TripStatus {
        .occurrence(departure: departure, scheduledArrival: arrival,
                    travelSeconds: drive.estimatedTravelTime, isCanceled: isCanceled,
                    startedAt: drive.lastStartedAt)
    }

    /// Start dot = departure status: green on time, yellow if late to depart, red if canceled.
    var startColor: Color {
        if isCanceled { return .red }
        if isDeparted { return .gray }
        return Date() > departure ? .yellow : .green
    }

    /// End dot mirrors the departure state (a drive that hasn't left yet can't be "late to arrive").
    var endColor: Color {
        if isCanceled { return .red }
        if isDeparted { return .gray }
        return Date() > departure ? .yellow : .green
    }
}

/// Airport-departures-board row: status dots + times, who's paying, destination, and a status chip.
struct DepartureRow: View {
    let occ: DriveOccurrence
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]

    var body: some View {
        let payer = PayerGroup.resolve(key: occ.drive.paidByRaw, in: payerGroups)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(occ.startColor).frame(width: 7, height: 7)
                    Text(occ.departure, format: .dateTime.hour().minute())
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit().lineLimit(1).fixedSize()
                }
                HStack(spacing: 6) {
                    Circle().fill(occ.endColor).frame(width: 7, height: 7)
                    Text(occ.arrival, format: .dateTime.hour().minute())
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            .frame(width: 86, alignment: .leading)

            Rectangle().fill(.secondary.opacity(0.25)).frame(width: 1, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: occ.drive.category.icon)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(occ.drive.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    Image(systemName: payer.icon)
                        .font(.caption2).foregroundStyle(payer.color)
                }
                HStack(spacing: 4) {
                    // Arrival (not departure) plane: this is the destination address, mirroring
                    // every other endpoint label in the app (ApplyScheduleSheet, TripSummaryView,
                    // StatsView's recent-trip card all pair the arrival glyph with the end address).
                    Image(systemName: "airplane.arrival").font(.caption2).foregroundStyle(.secondary)
                    Text(PlaceNamer.name(for: occ.drive.endCoordinate, fallback: occ.drive.endAddress, in: savedPlaces))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            StatusChip(status: occ.status, compact: true)
        }
        .padding(.vertical, 4)
        .opacity(occ.isCanceled ? 0.5 : 1)
    }
}
