import SwiftUI
import SwiftData

struct TripsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]
    @State private var searchText = ""
    @State private var pendingDelete: DriveTrip?

    private var filtered: [DriveTrip] {
        if searchText.isEmpty { return trips }
        return trips.filter {
            $0.startAddress.localizedCaseInsensitiveContains(searchText) ||
            $0.endAddress.localizedCaseInsensitiveContains(searchText) ||
            ($0.name?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView("No Trips Yet", systemImage: "road.lanes",
                                           description: Text("Record a drive from the Track tab and it'll show up here."))
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
                    .searchable(text: $searchText, prompt: "Search trips")
                    .refreshable { await TripStore.syncPending(context: context) }
                }
            }
            .background(.black)
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { TripMapView() } label: { Image(systemName: "map") }
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

    private func delete(_ trip: DriveTrip) {
        Haptics.warning()
        if let remoteID = trip.remoteID {
            Task { try? await APIClient.deleteTrip(id: remoteID) }
        }
        context.delete(trip)
    }
}

private struct TripRow: View {
    let trip: DriveTrip
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                PayerChip(payer: trip.paidBy, compact: true)
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
