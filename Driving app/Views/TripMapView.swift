import SwiftUI
import MapKit

struct TripMapView: View {
    @State private var trips: [APITrip] = []
    @State private var loading = true
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if trips.isEmpty {
                ContentUnavailableView("No Trips on Map", systemImage: "map", description: Text("Log trips to see them here"))
            } else {
                Map(position: $cameraPosition) {
                    ForEach(trips) { trip in
                        Marker(trip.startAddress, systemImage: "flag.fill", coordinate:
                            CLLocationCoordinate2D(latitude: trip.startLat, longitude: trip.startLng)
                        ).tint(.blue)
                        Marker(trip.endAddress, systemImage: "mappin", coordinate:
                            CLLocationCoordinate2D(latitude: trip.endLat, longitude: trip.endLng)
                        ).tint(.red)
                        MapPolyline(coordinates: [
                            CLLocationCoordinate2D(latitude: trip.startLat, longitude: trip.startLng),
                            CLLocationCoordinate2D(latitude: trip.endLat, longitude: trip.endLng),
                        ]).stroke(.blue.opacity(0.6), lineWidth: 3)
                    }
                }
                .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
            }
        }
        .navigationTitle("Trip Map")
        .task {
            do {
                trips = try await APIClient.fetchTrips()
            } catch {}
            loading = false
        }
    }
}
