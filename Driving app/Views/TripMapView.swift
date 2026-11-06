import SwiftUI
import SwiftData
import MapKit

struct TripMapView: View {
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]

    var body: some View {
        Group {
            if trips.isEmpty || allCoords.isEmpty {
                ContentUnavailableView("No Trips on Map", systemImage: "map",
                                       description: Text("Log trips to see them here"))
            } else {
                Map(initialPosition: .region(.enclosing(allCoords))) {
                    ForEach(trips) { trip in
                        let coords = trip.displayCoordinates.filter(\.isUsableCoordinate)
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
        trips.flatMap(routeCoords(for:))
    }

    /// A trip's recorded route, or — when it has no stored track (e.g. imported / pre-update records) —
    /// just its start and end points. Unusable (0, 0) coordinates are dropped: framing the camera on
    /// an empty or all-zero list parked the whole map on the equator in the middle of the Atlantic.
    private func routeCoords(for trip: DriveTrip) -> [CLLocationCoordinate2D] {
        let route = trip.displayCoordinates.filter(\.isUsableCoordinate)
        if route.count >= 2 { return route }
        return [trip.startCoordinate, trip.endCoordinate].filter(\.isUsableCoordinate)
    }
}
