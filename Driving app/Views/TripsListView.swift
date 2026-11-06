import SwiftUI
import SwiftData

struct TripsListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.tabActivityToken) private var activityToken
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]
    @State private var searchText = ""
    @State private var pendingDelete: DriveTrip?
    /// Compact one-and-a-half-line rows instead of the full card rows; remembered across launches.
    @AppStorage("tripsDenseMode") private var dense = false
    @State private var categoryFilter: TripCategory?
    @State private var payerFilter: String?
    @State private var period: Period = .all
    @State private var kindFilter: Kind = .all

    enum Period: String, CaseIterable, Identifiable {
        case all = "All time", week = "Past 7 days", month = "Past 30 days", year = "Past year"
        var id: String { rawValue }
        var cutoff: Date? {
            let cal = Calendar.current
            switch self {
            case .all: return nil
            case .week: return cal.date(byAdding: .day, value: -7, to: .now)
            case .month: return cal.date(byAdding: .day, value: -30, to: .now)
            case .year: return cal.date(byAdding: .year, value: -1, to: .now)
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All trips", journeys = "Journeys", diverted = "Diverted", favorites = "Favorites",
             manual = "Logged manually"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: "road.lanes"
            case .journeys: "arrow.triangle.branch"
            case .diverted: "arrow.triangle.turn.up.right.diamond.fill"
            case .favorites: "star.fill"
            case .manual: "square.and.pencil"
            }
        }
        func matches(_ t: DriveTrip) -> Bool {
            switch self {
            case .all: true
            case .journeys: t.isJourneyLeg
            case .diverted: t.divertedFromName != nil
            case .favorites: t.isFavorite
            case .manual: t.isManualEntry
            }
        }
    }

    private var hasActiveFilters: Bool {
        categoryFilter != nil || payerFilter != nil || period != .all || kindFilter != .all
    }

    private func clearFilters() {
        categoryFilter = nil; payerFilter = nil; period = .all; kindFilter = .all
    }

    private var filtered: [DriveTrip] {
        let cutoff = period.cutoff
        let base = trips.filter { t in
            (categoryFilter == nil || t.category == categoryFilter)
                && (payerFilter == nil || t.paidByRaw == payerFilter)
                && (cutoff == nil || t.date >= cutoff!)
                && kindFilter.matches(t)
        }
        if searchText.isEmpty { return base }
        return base.filter {
            $0.category.label.localizedCaseInsensitiveContains(searchText) ||
            ($0.notes?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            $0.startAddress.localizedCaseInsensitiveContains(searchText) ||
            $0.endAddress.localizedCaseInsensitiveContains(searchText) ||
            ($0.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            // Rows display the bookmarked-place name ("Home"), not the raw address, whenever one's
            // nearby (see `TripRow`'s use of `PlaceNamer.name`) — searching only the raw address
            // meant typing exactly what's printed on screen ("Home") could return no results at all.
            PlaceNamer.name(for: $0.startCoordinate, fallback: "", in: savedPlaces).localizedCaseInsensitiveContains(searchText) ||
            PlaceNamer.name(for: $0.endCoordinate, fallback: "", in: savedPlaces).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView("No Trips Yet", systemImage: "road.lanes",
                                           description: Text("Record a drive from the Drive tab and it'll show up here."))
                } else if filtered.isEmpty {
                    if hasActiveFilters {
                        ContentUnavailableView {
                            Label("No Matching Trips", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No trips match the current filters.")
                        } actions: {
                            Button("Clear Filters") { clearFilters() }
                        }
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    List {
                        ForEach(listRows) { row in
                            switch row {
                            case .trip(let trip):
                                NavigationLink {
                                    TripDetailView(trip: trip)
                                } label: {
                                    if dense { DenseTripRow(trip: trip) } else { TripRow(trip: trip) }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = trip } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            case .connection(_, let seconds, let place):
                                // Layered between the two trips that share this stop, Flighty-style.
                                ConnectionPill(seconds: seconds, placeName: place, compact: dense)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .padding(.vertical, -2)
                            }
                        }
                    }
                }
            }
            .background(.black)
            .safeAreaInset(edge: .top, spacing: 0) {
                if hasActiveFilters { activeFilterBar }
            }
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.inline)
            // Was on the `List` inside the non-empty `else` branch above — the moment a search query
            // matched nothing, `filtered.isEmpty` swapped in `ContentUnavailableView.search(text:)`
            // in place of the `List`, tearing `.searchable` out of the view hierarchy along with it.
            // The search field (and keyboard) vanished mid-keystroke and `searchText` had no way to
            // be edited or cleared short of leaving and re-entering the tab. `.searchable` now lives
            // on the `Group` so it stays mounted across every branch, exactly so
            // `ContentUnavailableView.search` (designed to be shown WHILE the search bar is still
            // present) can do its job.
            .searchable(text: $searchText, prompt: "Search trips")
            // Was only on the `List` inside the non-empty branch above — pulling down on the empty
            // state (exactly when a user expects a refresh to fix "outdated/missing trips") did
            // nothing at all, not even attempt a sync, because there was no gesture attached there.
            .refreshable { await refresh() }
            // `syncPending` only ever pushed local trips up; nothing pulled server-side edits (the
            // fields actually editable from the web dashboard — category, notes, favorite, payer)
            // back down, so "pull to refresh" could never surface a change made anywhere but this
            // phone. Trip *creation* stays phone-only on purpose (a server row has no GPS track, no
            // speed stats, none of what makes a recorded trip a recorded trip — see
            // `TripStore.pullRemoteEdits`), but edits to those few fields now sync both ways.
            .task(id: activityToken) { await refresh() }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { dense.toggle() }
                    } label: {
                        Image(systemName: dense ? "list.bullet.below.rectangle" : "list.bullet")
                    }
                    .accessibilityLabel(dense ? "Switch to detailed rows" : "Switch to dense rows")
                    filterMenu
                    NavigationLink { TripMapView() } label: { Image(systemName: "map") }
                        .accessibilityLabel("Trip map")
                }
            }
            .confirmationDialog("Delete this trip?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Trip", role: .destructive) {
                    if let t = pendingDelete { delete(t) }
                    pendingDelete = nil
                }
            } message: {
                Text("This permanently removes the recorded drive and its track.")
            }
        }
    }

    // MARK: - Filters

    private var filterMenu: some View {
        Menu {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Type", selection: $kindFilter) {
                ForEach(Kind.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            Menu("Category") {
                Picker("Category", selection: $categoryFilter) {
                    Text("Any category").tag(TripCategory?.none)
                    ForEach(TripCategory.allCases, id: \.self) { c in
                        Label(c.label, systemImage: c.icon).tag(TripCategory?.some(c))
                    }
                }
            }
            Menu("Paid by") {
                Picker("Paid by", selection: $payerFilter) {
                    Text("Anyone").tag(String?.none)
                    ForEach(payerGroups) { g in
                        Label(g.name, systemImage: g.icon).tag(String?.some(g.key))
                    }
                }
            }
            if hasActiveFilters {
                Divider()
                Button("Clear Filters", role: .destructive) { clearFilters() }
            }
        } label: {
            Image(systemName: hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter trips")
    }

    /// Chips for whatever filters are on, plus a live result count and a one-tap clear.
    private var activeFilterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if period != .all { chip(period.rawValue, "calendar") { period = .all } }
                    if kindFilter != .all { chip(kindFilter.rawValue, kindFilter.icon) { kindFilter = .all } }
                    if let c = categoryFilter { chip(c.label, c.icon) { categoryFilter = nil } }
                    if let k = payerFilter {
                        let g = PayerGroup.resolve(key: k, in: payerGroups)
                        chip(g.name, g.icon) { payerFilter = nil }
                    }
                }
            }
            Text("\(filtered.count) trip\(filtered.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Button("Clear") { clearFilters() }.font(.caption.weight(.semibold))
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func chip(_ text: String, _ icon: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(text).font(.caption.weight(.medium))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.2), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    enum ListRow: Identifiable {
        case trip(DriveTrip)
        case connection(id: String, seconds: Int, place: String)
        var id: String {
            switch self {
            case .trip(let t): return "t-\(t.persistentModelID.hashValue)"
            case .connection(let id, _, _): return id
            }
        }
    }

    /// Trips (newest first) with a connection pill slotted between every adjacent pair where the
    /// older trip ended where the newer one began, under 3 hours apart. Both trips must be visible
    /// (i.e. survive the current search/filters) for the pill to show.
    private var listRows: [ListRow] {
        let items = filtered
        var rows: [ListRow] = []
        for (i, later) in items.enumerated() {
            rows.append(.trip(later))
            guard i + 1 < items.count else { continue }
            let earlier = items[i + 1]
            if let secs = Connection.gap(from: earlier, to: later) {
                let place = PlaceNamer.name(for: earlier.endCoordinate, fallback: earlier.endAddress, in: savedPlaces)
                rows.append(.connection(id: "c-\(earlier.persistentModelID.hashValue)", seconds: secs, place: place))
            }
        }
        return rows
    }

    private func refresh() async {
        await TripStore.syncPending(context: context)
        await TripStore.pullRemoteEdits(context: context)
    }

    private func delete(_ trip: DriveTrip) {
        Haptics.warning()
        let jid = trip.journeyID
        if let remoteID = trip.remoteID {
            Task { try? await APIClient.deleteTrip(id: remoteID) }
        }
        context.delete(trip)
        try? context.save()
        // Renumber the rest of the journey (or demote a lone survivor to a standalone trip).
        TripStore.renumberJourney(jid, context: context)
    }
}

/// Dense variant: route on the first line with distance, one caption line for everything else.
private struct DenseTripRow: View {
    let trip: DriveTrip
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if trip.isJourneyLeg {
                    Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.purple)
                }
                if trip.divertedFromName != nil {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: "%.1f mi", trip.distance))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            HStack(spacing: 6) {
                Group {
                    Text(dateLabel(trip.date))
                    Text("· \(Fmt.duration(trip.duration))")
                    Image(systemName: trip.category.icon)
                    }
                .fixedSize()
                if let n = trip.name, !n.isEmpty { Text("· \(n)").lineLimit(1) }
                Spacer(minLength: 4)
                if trip.delaySeconds != nil {
                    StatusChip(status: .forTrip(delaySeconds: trip.delaySeconds), compact: true)
                }
                if !trip.synced { Image(systemName: "icloud.slash") }
                PayerChip(PayerGroup.resolve(key: trip.paidByRaw, in: payerGroups), compact: true)
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 0)
    }

    private var title: String {
        let a = PlaceNamer.name(for: trip.startCoordinate, fallback: trip.startAddress, in: savedPlaces)
        let b = PlaceNamer.name(for: trip.endCoordinate, fallback: trip.endAddress, in: savedPlaces)
        return "\(a) → \(b)"
    }

    private func dateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yest. \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct TripRow: View {
    let trip: DriveTrip
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if trip.isJourneyLeg {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.caption2)
                    Text("Journey · Leg \(trip.legIndex + 1) of \(trip.legTotal)")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.purple.opacity(0.18), in: .capsule)
            }
            if let from = trip.divertedFromName {
                Label("Diverted from \(from)", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.orange).lineLimit(1)
            }
            if trip.isManualEntry {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil").font(.caption2)
                    Text("Not Recorded — Logged Manually")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.orange.opacity(0.18), in: .capsule)
            }
            if let name = trip.name, !name.isEmpty {
                Text(name)
                    .font(.headline).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(dateLabel(trip.date))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if trip.delaySeconds != nil {
                    StatusChip(status: .forTrip(delaySeconds: trip.delaySeconds), compact: true)
                }
                Text(String(format: "%.1f mi", trip.distance))
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: .capsule)
            }
            Text(PlaceNamer.name(for: trip.startCoordinate, fallback: trip.startAddress, in: savedPlaces))
                .font(.subheadline).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(PlaceNamer.name(for: trip.endCoordinate, fallback: trip.endAddress, in: savedPlaces))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                stat(trip.category.icon, trip.category.label)
                stat("clock.fill", Fmt.duration(trip.duration))
                stat("fuelpump.fill", String(format: "%.2f gal", trip.estimatedGallons))
                Spacer(minLength: 4)
                if !trip.synced { Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.tertiary) }
                PayerChip(PayerGroup.resolve(key: trip.paidByRaw, in: payerGroups), compact: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2)
        }
        .foregroundStyle(.tertiary)
    }

    /// "Today 3:14 PM", "Yesterday 9:02 AM", else "Jun 27 at 8:19 PM".
    private func dateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
