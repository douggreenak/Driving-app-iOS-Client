import SwiftUI
import SwiftData

struct TripsListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.tabActivityToken) private var activityToken
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @State private var searchText = ""
    @State private var pendingDelete: DriveTrip?

    private var filtered: [DriveTrip] {
        if searchText.isEmpty { return trips }
        return trips.filter {
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
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filtered) { trip in
                            NavigationLink {
                                TripDetailView(trip: trip)
                            } label: {
                                TripRow(trip: trip)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = trip } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .background(.black)
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
                ToolbarItem(placement: .primaryAction) {
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
