import SwiftUI
import MapKit
import SwiftData

struct TripMapView: View {
    @Query private var trips: [Trip]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var categoryFilter: TripCategory?

    private var filteredTrips: [Trip] {
        if let cat = categoryFilter {
            return trips.filter { $0.category == cat }
        }
        return trips
    }

    private var categories: [TripCategory] {
        Array(Set(trips.map(\.category))).sorted { $0.label < $1.label }
    }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView(
                        "No Trips on Map",
                        systemImage: "map",
                        description: Text("Log trips to see them here")
                    )
                } else {
                    VStack(spacing: 0) {
                        if categories.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    Button {
                                        withAnimation { categoryFilter = nil }
                                    } label: {
                                        Text("All")
                                            .font(.caption)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(categoryFilter == nil ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                                    }
                                    .buttonStyle(.plain)

                                    ForEach(categories, id: \.self) { cat in
                                        Button {
                                            withAnimation { categoryFilter = categoryFilter == cat ? nil : cat }
                                        } label: {
                                            Label(cat.label, systemImage: cat.icon)
                                                .font(.caption)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(categoryFilter == cat ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                        }

                        Map(position: $cameraPosition) {
                            ForEach(filteredTrips) { trip in
                                Marker(trip.startAddress, systemImage: "flag.fill", coordinate:
                                    CLLocationCoordinate2D(latitude: trip.startLat, longitude: trip.startLng)
                                ).tint(.blue)

                                Marker(trip.endAddress, systemImage: "mappin", coordinate:
                                    CLLocationCoordinate2D(latitude: trip.endLat, longitude: trip.endLng)
                                ).tint(.red)

                                MapPolyline(coordinates: [
                                    CLLocationCoordinate2D(latitude: trip.startLat, longitude: trip.startLng),
                                    CLLocationCoordinate2D(latitude: trip.endLat, longitude: trip.endLng),
                                ])
                                .stroke(.blue.opacity(0.6), lineWidth: 3)
                            }
                        }
                        .mapControls {
                            MapUserLocationButton()
                            MapCompass()
                            MapScaleView()
                        }
                    }
                }
            }
            .navigationTitle("Trip Map")
        }
    }
}
