import SwiftUI
import SwiftData

struct TripsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trip.date, order: .reverse) private var trips: [Trip]
    @State private var showingNewTrip = false
    @State private var searchText = ""
    @State private var categoryFilter: TripCategory?
    @State private var showFavoritesOnly = false

    private var filteredTrips: [Trip] {
        var result = trips
        if !searchText.isEmpty {
            result = result.filter {
                $0.startAddress.localizedCaseInsensitiveContains(searchText) ||
                $0.endAddress.localizedCaseInsensitiveContains(searchText) ||
                ($0.notes ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        if let cat = categoryFilter {
            result = result.filter { $0.category == cat }
        }
        if showFavoritesOnly {
            result = result.filter { $0.isFavorite }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView(
                        "No Trips Yet",
                        systemImage: "road.lanes",
                        description: Text("Start tracking your drives")
                    )
                } else {
                    List {
                        ForEach(filteredTrips) { trip in
                            TripRow(trip: trip)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(trip)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        trip.isFavorite.toggle()
                                    } label: {
                                        Label(
                                            trip.isFavorite ? "Unfavorite" : "Favorite",
                                            systemImage: trip.isFavorite ? "star.slash" : "star.fill"
                                        )
                                    }
                                    .tint(.yellow)
                                }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search trips")
                }
            }
            .navigationTitle("Trips")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        NavigationLink {
                            TripMapView()
                        } label: {
                            Image(systemName: "map")
                        }
                        Button { showingNewTrip = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button {
                            showFavoritesOnly.toggle()
                        } label: {
                            Label(
                                showFavoritesOnly ? "Show All" : "Favorites Only",
                                systemImage: showFavoritesOnly ? "star.slash" : "star.fill"
                            )
                        }
                        Divider()
                        ForEach(TripCategory.allCases, id: \.self) { cat in
                            Button {
                                categoryFilter = categoryFilter == cat ? nil : cat
                            } label: {
                                Label(cat.label, systemImage: cat.icon)
                                if categoryFilter == cat {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showingNewTrip) {
                NewTripView()
            }
        }
    }
}

private struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    if trip.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(trip.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(trip.category.label, systemImage: trip.category.icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f mi", trip.distance))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: .capsule)
            }
            Text(trip.startAddress)
                .font(.subheadline)
                .fontWeight(.medium)
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(trip.endAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let notes = trip.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .padding(.vertical, 4)
    }
}
