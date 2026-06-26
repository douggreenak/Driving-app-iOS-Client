import SwiftUI

struct TripsListView: View {
    @State private var trips: [APITrip] = []
    @State private var loading = true
    @State private var showingNewTrip = false
    @State private var searchText = ""

    private var filteredTrips: [APITrip] {
        if searchText.isEmpty { return trips }
        return trips.filter {
            $0.startAddress.localizedCaseInsensitiveContains(searchText) ||
            $0.endAddress.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().padding(.top, 80)
                } else if trips.isEmpty {
                    ContentUnavailableView("No Trips Yet", systemImage: "road.lanes", description: Text("Start tracking your drives"))
                } else {
                    List {
                        ForEach(filteredTrips) { trip in
                            TripRow(trip: trip)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { deleteTrip(trip) } label: {
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        NavigationLink { TripMapView() } label: {
                            Image(systemName: "map")
                        }
                        Button { showingNewTrip = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingNewTrip) {
                NewTripView { await loadTrips() }
            }
            .refreshable { await loadTrips() }
            .task { await loadTrips() }
        }
    }

    private func loadTrips() async {
        do {
            trips = try await APIClient.fetchTrips()
            loading = false
        } catch { loading = false }
    }

    private func deleteTrip(_ trip: APITrip) {
        Task {
            try? await APIClient.deleteTrip(id: trip.id)
            trips.removeAll { $0.id == trip.id }
        }
    }
}

private struct TripRow: View {
    let trip: APITrip
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trip.parsedDate, style: .date)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label(trip.tripCategory.label, systemImage: trip.tripCategory.icon)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.1f mi", trip.distance))
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: .capsule)
            }
            Text(trip.startAddress).font(.subheadline).fontWeight(.medium)
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(trip.endAddress).font(.subheadline).foregroundStyle(.secondary)
            }
            if let notes = trip.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.tertiary).italic()
            }
        }
        .padding(.vertical, 4)
    }
}
