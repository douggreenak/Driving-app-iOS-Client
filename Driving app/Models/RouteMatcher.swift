import Foundation
import CoreLocation
import MapKit

/// Fits a raw GPS track to the road network.
///
/// Strategy:
///  1. Ask MapKit for candidate driving routes between the track's endpoints (including
///     alternates) — these follow real roads.
///  2. Score each candidate by how well it fits the *actual* GPS data (mean distance from the
///     recorded points to the route), using travel time (efficiency) only to break near-ties.
///  3. With the winning route, classify every recorded point as on-road (within tolerance →
///     snapped onto the route) or a deviation (kept as raw GPS). Genuine detours survive; the
///     drive is not force-fit onto the suggested route.
enum RouteMatcher {

    struct Result {
        /// Display polyline: snapped where the driver was on a known road, raw GPS on detours.
        var coordinates: [CLLocationCoordinate2D]
        /// Per-input-point flag: was this point on a known road?
        var onRoad: [Bool]
        /// Mean fit error in meters between GPS and the chosen route.
        var fitMeters: Double
        /// Fraction of points that matched a road (0–1).
        var matchedFraction: Double
        /// Whether a road route was actually used (false → raw fallback, e.g. offline).
        var usedRoute: Bool
    }

    /// Points within this distance of a candidate road are considered "on road".
    static let toleranceMeters: Double = 35

    /// Fetch candidate driving routes between two coordinates. Returns [] on failure (e.g. offline).
    static func candidateRoutes(from start: CLLocationCoordinate2D,
                                to end: CLLocationCoordinate2D) async -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        do {
            return try await MKDirections(request: request).calculate().routes
        } catch {
            return []
        }
    }

    /// Total expected travel seconds and the combined road polyline across an ordered list of
    /// waypoints (start → stops → destination), summing the fastest route for each leg. Returns nil
    /// if any leg has no available route (e.g. offline). Used for multi-stop scheduled drives and
    /// route cost prediction.
    static func multiLegRoute(through waypoints: [CLLocationCoordinate2D])
        async -> (seconds: Int, coordinates: [CLLocationCoordinate2D])? {
        guard waypoints.count >= 2 else { return nil }
        var totalSeconds = 0
        var coords: [CLLocationCoordinate2D] = []
        for i in 1..<waypoints.count {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[i - 1]))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[i]))
            request.transportType = .automobile
            guard let response = try? await MKDirections(request: request).calculate(),
                  let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime })
            else { return nil }
            totalSeconds += Int(route.expectedTravelTime)
            coords.append(contentsOf: route.polyline.coordinates())
        }
        return (totalSeconds, coords)
    }

    /// Match a recorded track to roads. `points` must be in chronological order.
    static func match(points: [RecordedPoint]) async -> Result {
        let coords = points.map(\.coordinate)
        guard let start = coords.first, let end = coords.last, coords.count >= 2 else {
            return Result(coordinates: coords, onRoad: Array(repeating: false, count: coords.count),
                          fitMeters: 0, matchedFraction: 0, usedRoute: false)
        }

        let routes = await candidateRoutes(from: start, to: end)
        guard !routes.isEmpty else {
            // Offline / no route available: keep the raw track.
            return Result(coordinates: coords, onRoad: Array(repeating: false, count: coords.count),
                          fitMeters: 0, matchedFraction: 0, usedRoute: false)
        }

        let plane = LocalPlane(reference: start)

        // Project each candidate route's polyline into the local plane once.
        let projected: [[(x: Double, y: Double)]] = routes.map { route in
            route.polyline.coordinates().map { plane.xy($0) }
        }
        let gps = coords.map { plane.xy($0) }
        let fastest = routes.map(\.expectedTravelTime).min() ?? 1

        // Score = mean GPS-to-route distance, lightly penalized for inefficiency.
        var best = 0
        var bestScore = Double.greatestFiniteMagnitude
        for (i, poly) in projected.enumerated() {
            guard poly.count >= 2 else { continue }
            let fit = meanFit(gps: gps, route: poly)
            let inefficiency = routes[i].expectedTravelTime / max(fastest, 1) - 1  // 0 for the fastest
            let score = fit + inefficiency * 15  // ~15 m of fit per 100% slower → tie-breaker only
            if score < bestScore {
                bestScore = score
                best = i
            }
        }

        let route = projected[best]
        var onRoad = [Bool](repeating: false, count: coords.count)
        var display: [CLLocationCoordinate2D] = []
        display.reserveCapacity(coords.count)
        var matched = 0
        var fitSum = 0.0

        for (i, p) in gps.enumerated() {
            let (dist, proj) = nearest(point: p, on: route)
            fitSum += dist
            if dist <= toleranceMeters {
                onRoad[i] = true
                matched += 1
                display.append(plane.coordinate(x: proj.x, y: proj.y))  // snap to road
            } else {
                display.append(coords[i])  // keep the real detour
            }
        }

        return Result(
            coordinates: simplify(display, tolerance: 4),
            onRoad: onRoad,
            fitMeters: fitSum / Double(gps.count),
            matchedFraction: Double(matched) / Double(coords.count),
            usedRoute: true
        )
    }

    // MARK: - Geometry

    private static func meanFit(gps: [(x: Double, y: Double)], route: [(x: Double, y: Double)]) -> Double {
        guard !gps.isEmpty else { return .greatestFiniteMagnitude }
        var sum = 0.0
        for p in gps { sum += nearest(point: p, on: route).distance }
        return sum / Double(gps.count)
    }

    /// Nearest point on a polyline (in planar meters) to `point`, with the distance to it.
    private static func nearest(point p: (x: Double, y: Double),
                                on poly: [(x: Double, y: Double)]) -> (distance: Double, point: (x: Double, y: Double)) {
        var bestD = Double.greatestFiniteMagnitude
        var bestPt = poly.first ?? p
        if poly.count == 1 {
            return (hypot(p.x - bestPt.x, p.y - bestPt.y), bestPt)
        }
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            let proj = projectOntoSegment(p, a, b)
            let d = hypot(p.x - proj.x, p.y - proj.y)
            if d < bestD { bestD = d; bestPt = proj }
        }
        return (bestD, bestPt)
    }

    private static func projectOntoSegment(_ p: (x: Double, y: Double),
                                           _ a: (x: Double, y: Double),
                                           _ b: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return a }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return (a.x + t * dx, a.y + t * dy)
    }

    /// Ramer–Douglas–Peucker-ish thinning to drop redundant collinear points (meters tolerance).
    private static func simplify(_ coords: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var out: [CLLocationCoordinate2D] = [coords[0]]
        for i in 1..<coords.count - 1 {
            if coords[i].distanceMeters(to: out.last!) >= tolerance {
                out.append(coords[i])
            }
        }
        out.append(coords.last!)
        return out
    }
}

extension MKPolyline {
    func coordinates() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
