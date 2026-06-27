import SwiftUI
import SwiftData

struct TripsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]
    @State private var searchText = ""

    private var filtered: [DriveTrip] {
        if searchText.isEmpty { return trips }
        return trips.filter {
            $0.startAddress.localizedCaseInsensitiveContains(searchText) ||
            $0.endAddress.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView("No Trips Yet", systemImage: "road.lanes",
                                           description: Text("Start tracking your drives on the Track tab"))
                } else {
                    List {
                        ForEach(filtered) { trip in
                            NavigationLink {
                                TripDetailView(trip: trip)
                            } label: {
                                TripRow(trip: trip)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { delete(trip) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search trips")
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
        }
    }

    private func delete(_ trip: DriveTrip) {
        if let remoteID = trip.remoteID {
            Task { try? await APIClient.deleteTrip(id: remoteID) }
        }
        context.delete(trip)
    }
}

private struct TripRow: View {
    let trip: DriveTrip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(trip.date, format: .dateTime.month().day().hour().minute())
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
            Text(trip.startAddress).font(.subheadline).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(trip.endAddress).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                stat(trip.category.icon, trip.category.label)
                stat("clock.fill", durationString(trip.duration))
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

    private func durationString(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }
}
