import SwiftUI
import SwiftData
import MapKit

struct TripMapView: View {
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]

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
                    }
                }
                .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
                // `initialPosition` is consumed once, at first layout — a trip synced in or logged
                // while this screen happens to be open extended the polylines but never the camera.
                // `.id` forces a fresh map identity (and a fresh `initialPosition` read) whenever the
                // trip count changes.
                .id(trips.count)
            }
        }
        .navigationTitle("Trip Map")
    }

    /// Every trip's FULL route, not just its start/end pair — the framing used to only consider the
    /// two endpoints, so any route that bows outside that bounding box got clipped at the map's
    /// edges. Most obviously broken for a round trip, whose start and end are the same point (a
    /// degenerate zero-span "pair") despite the polyline actually drawn covering real ground.
    private var allCoords: [CLLocationCoordinate2D] {
        trips.flatMap(\.displayCoordinates)
    }
}
