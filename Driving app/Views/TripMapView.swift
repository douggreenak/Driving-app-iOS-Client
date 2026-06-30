import SwiftUI
import SwiftData
import MapKit

struct TripMapView: View {
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]

    var body: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView("No Trips on Map", systemImage: "map",
                                       description: Text("Log trips to see them here"))
            } else {
                Map(initialPosition: .region(.enclosing(allCoords))) {
                    ForEach(trips) { trip in
                        let coords = trip.displayCoordinates
                        if coords.count >= 2 {
                            MapPolyline(coordinates: coords)
                                .stroke(.blue.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }
                        Marker(PlaceNamer.name(for: trip.endCoordinate, fallback: trip.endAddress, in: savedPlaces),
                               systemImage: "mappin", coordinate: trip.endCoordinate)
                            .tint(.red)
                    }
                }
                .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
            }
        }
        .navigationTitle("Trip Map")
    }

    private var allCoords: [CLLocationCoordinate2D] {
        trips.flatMap { [$0.startCoordinate, $0.endCoordinate] }
    }
}
