import SwiftUI
import SwiftData
import MapKit

/// Every recorded route on one map.
///
/// This used to decode every trip's stored polyline (and, for trips without one, fault in thousands of
/// `TrackPoint` rows) inside `body` — twice per render — and hand the map one full-resolution
/// `MapPolyline` per trip. With a few hundred trips that is hundreds of thousands of points on the main
/// thread each time anything changed, which is why the map got slower the more you drove.
///
/// Now the routes are decoded and thinned ONCE, off the main thread, into a cache; `body` only draws
/// the cached, simplified lines.
struct TripMapView: View {
    @Query(sort: \DriveTrip.date, order: .reverse) private var trips: [DriveTrip]
    @State private var lines: [Line] = []
    @State private var region: MKCoordinateRegion?
    @State private var loading = true
    /// What the cache was built from, so it only rebuilds when the trips really changed.
    @State private var builtFor: Int = -1

    struct Line: Identifiable {
        let id: Int
        let coords: [CLLocationCoordinate2D]
    }

    private struct Source: Sendable {
        let polyline: Data?
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
    }

    /// Cheap fingerprint of the trip set (count + newest/oldest + total of polyline sizes would be
    /// overkill; any added/removed/edited-route trip changes one of these).
    private var token: Int {
        var h = Hasher()
        h.combine(trips.count)
        h.combine(trips.first?.date)
        h.combine(trips.last?.date)
        h.combine(trips.first?.matchedPolyline?.count)
        return h.finalize()
    }

    var body: some View {
        Group {
            if lines.isEmpty {
                if loading {
                    ProgressView("Loading routes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Trips on Map", systemImage: "map",
                                           description: Text("Log trips to see them here"))
                }
            } else {
                Map(initialPosition: .region(region ?? .enclosing(lines.flatMap(\.coords)))) {
                    ForEach(lines) { line in
                        MapPolyline(coordinates: line.coords)
                            .stroke(.blue.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
                // A fresh map identity (and a fresh `initialPosition` read) whenever the cache rebuilds.
                .id(builtFor)
            }
        }
        .navigationTitle("Trip Map")
        .task(id: token) { await rebuild() }
    }

    private func rebuild() async {
        let sources = trips.map { Source(polyline: $0.matchedPolyline, start: $0.startCoordinate, end: $0.endCoordinate) }
        let key = token
        let result = await Task.detached(priority: .userInitiated) { Self.build(sources) }.value
        lines = result.lines
        region = result.region
        builtFor = key
        loading = false
    }

    // MARK: Off-main work

    nonisolated private static func build(_ sources: [Source]) -> (lines: [Line], region: MKCoordinateRegion?) {
        // Thin each route so the whole map stays under a fixed point budget however many trips exist.
        let budget = 30_000
        var tolerance = 15.0
        var decoded: [[CLLocationCoordinate2D]] = sources.map { src in
            if let data = src.polyline,
               let arr = try? JSONDecoder().decode([[Double]].self, from: data) {
                let pts = arr.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
                    .filter(\.isUsableCoordinate)
                if pts.count >= 2 { return pts }
            }
            return [src.start, src.end].filter(\.isUsableCoordinate)
        }
        var simplified = decoded.map { thin($0, minMeters: tolerance) }
        while simplified.reduce(0, { $0 + $1.count }) > budget, tolerance < 400 {
            tolerance *= 1.8
            simplified = decoded.map { thin($0, minMeters: tolerance) }
        }
        decoded = []
        let lines = simplified.enumerated().compactMap { i, c in c.count >= 2 ? Line(id: i, coords: c) : nil }
        let all = lines.flatMap(\.coords)
        return (lines, all.isEmpty ? nil : .enclosing(all))
    }

    /// Keeps a point only when it is at least `minMeters` from the last kept one (always keeps the
    /// first and last), which preserves the shape of a drive at map-overview zoom.
    nonisolated private static func thin(_ pts: [CLLocationCoordinate2D], minMeters: Double) -> [CLLocationCoordinate2D] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() where p.distanceMeters(to: out[out.count - 1]) >= minMeters { out.append(p) }
        out.append(pts[pts.count - 1])
        return out
    }
}
