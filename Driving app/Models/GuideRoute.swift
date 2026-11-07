import Foundation
import CoreLocation
import MapKit
import Observation

/// One maneuver on the guide route ("Turn left onto Main St").
struct GuideStep {
    var instruction: String
    var start: CLLocationCoordinate2D
    /// Metres along the route polyline from its start to where this maneuver happens.
    var offset: Double = 0
}

/// The most-efficient (fastest) road route from where the driver is now to the current target:
/// drawn on the map as the dotted light-blue guide line, and the source of the "next turn" shown on
/// the phone, the Lock Screen Live Activity and the Apple Watch.
///
/// Lives on `ActiveDriveController` (not in the map view) so it keeps refreshing — and the Watch /
/// Live Activity keep getting the next turn — while the drive is minimized and no map exists.
@Observable
@MainActor
final class GuideRoute {
    /// The route polyline ahead (empty when there's no target or no route yet).
    private(set) var coordinates: [CLLocationCoordinate2D] = []
    private(set) var steps: [GuideStep] = []
    /// The next maneuver and the straight-line metres to it (nil when none/unknown).
    private(set) var nextTurn: String?
    private(set) var nextTurnMeters: Double?
    /// Total metres along the polyline still ahead of the current position (nil until a route exists).
    private(set) var remainingMeters: Double?

    private var lastFetchFrom: CLLocationCoordinate2D?
    private var lastFetchedTarget: CLLocationCoordinate2D?
    private var inFlight = false
    private var requestID = 0
    private var lastFailedAt: Date?
    private var stepIndex = 0
    /// Cumulative metres along `coordinates` at each vertex, and the last segment we were on (so the
    /// along-route position only ever searches near where we already were).
    private var cumulative: [Double] = []
    private var lastSegment = 0
    private var alongRoute = 0.0
    /// Consecutive fixes projected more than `offRouteMeters` from the line — a real wrong turn,
    /// not one bad fix.
    private var offRouteCount = 0
    private static let offRouteMeters = 60.0
    /// Re-fetch after this much movement even while on route, so the ETA tracks live traffic.
    private static let trafficRefreshMeters = 2000.0

    /// Forget the route (leg changed, drive ended, diverted…).
    func clear() {
        coordinates = []; steps = []; nextTurn = nil; nextTurnMeters = nil; remainingMeters = nil
        lastFetchFrom = nil; stepIndex = 0
        cumulative = []; lastSegment = 0; alongRoute = 0; offRouteCount = 0
    }

    /// Force the next `refresh` to re-fetch even though the driver hasn't moved.
    func invalidate() { lastFetchFrom = nil }

    /// Fetch the fastest route to `tracker.destination` from the current location.
    ///
    /// Re-routes when the car has genuinely left the line (several consecutive fixes well off it —
    /// see `updateNextTurn`), and otherwise only every ~2 km for traffic. The old rule re-fetched
    /// every 250 m regardless, and wiped the line the moment the car was 800 m from the route's
    /// START — i.e. every half mile of normal driving the turn banner blanked until MapKit answered.
    /// The current line is kept on screen until the replacement arrives.
    ///
    /// Guards against three real failure modes: slow first fetches re-requested on every ~1 Hz fix
    /// (MapKit then throttles us into never drawing anything), late responses for a leg the driver
    /// already left overwriting the fresh line, and a failed attempt counting as "we tried from here"
    /// (leaving a stale line for the rest of the drive).
    func refresh(tracker: LocationTracker) {
        guard !tracker.isPausedBetweenLegs,
              let dest = tracker.destination, dest.isUsableCoordinate,
              let from = tracker.currentLocation
        else { return }
        // Target changed under us (next leg / diversion) → the old line is wrong.
        if let t = lastFetchedTarget, !t.isApproximately(dest, toleranceMeters: 30) { clear() }
        guard !inFlight else { return }
        if let last = lastFetchFrom {
            let moved = from.distanceMeters(to: last)
            let offRoute = offRouteCount >= 3
            guard offRoute || moved >= Self.trafficRefreshMeters || coordinates.isEmpty && moved >= 100 else { return }
        }
        if let failed = lastFailedAt, Date().timeIntervalSince(failed) < 5 { return }

        inFlight = true
        requestID += 1
        let id = requestID
        Task { @MainActor in
            // Fastest of Apple Maps' alternates by its traffic-aware time; fall back to the plain
            // single-route request so a failure of the (heavier) alternates query can never leave the
            // map with no guide line at all.
            var route = await RouteMatcher.fastestRoute(from: from, to: dest)?.route
            if route == nil { route = await RouteMatcher.candidateRoutes(from: from, to: dest).first }
            inFlight = false
            guard id == requestID, tracker.destination.map({ $0.isApproximately(dest, toleranceMeters: 30) }) == true
            else { return }
            guard let route, route.polyline.pointCount >= 2 else { lastFailedAt = Date(); return }
            lastFetchFrom = from
            lastFetchedTarget = dest
            lastFailedAt = nil
            coordinates = route.polyline.coordinates()
            cumulative = Self.cumulativeLengths(coordinates)
            // Each maneuver's position ALONG the route = the summed length of every step before it
            // (empty-instruction steps still take up road, so they count toward the offset).
            var offset = 0.0
            var built: [GuideStep] = []
            for s in route.steps where s.polyline.pointCount > 0 {
                if !s.instructions.isEmpty {
                    built.append(GuideStep(instruction: s.instructions, start: s.polyline.coordinates()[0], offset: offset))
                }
                offset += s.distance
            }
            steps = built
            stepIndex = 0; lastSegment = 0; alongRoute = 0; offRouteCount = 0
            tracker.appleMapsExpectedTravelTime = route.expectedTravelTime
            tracker.appleMapsTravelTimeFetchDate = Date()
            updateNextTurn(from: from)
        }
    }

    /// Publish the next maneuver STILL AHEAD of the car.
    ///
    /// This used to treat a maneuver as "reached" as soon as the car was within 35 m of it — so for the
    /// last 35 m of approaching a turn the banner already jumped to the turn AFTER it ("turn onto B"
    /// while you were still short of A). Now the car's position is projected onto the route polyline,
    /// and a maneuver only counts as done once the car has actually passed it along the route; the
    /// distance shown is the distance along the road, not a straight line.
    func updateNextTurn(from here: CLLocationCoordinate2D?) {
        guard let here else { return }
        guard coordinates.count >= 2, cumulative.count == coordinates.count else {
            nextTurn = nil; nextTurnMeters = nil
            return
        }
        let plane = LocalPlane(reference: here)
        let p = (x: 0.0, y: 0.0)
        func project(_ range: Range<Int>) -> (dist: Double, along: Double, seg: Int)? {
            var best: (dist: Double, along: Double, seg: Int)?
            for i in range {
                let a = plane.xy(coordinates[i - 1]), b = plane.xy(coordinates[i])
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                var t = len2 == 0 ? 0 : ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
                t = max(0, min(1, t))
                let d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
                if best == nil || d < best!.dist {
                    best = (d, cumulative[i - 1] + t * (cumulative[i] - cumulative[i - 1]), i)
                }
            }
            return best
        }
        let n = coordinates.count
        let lo = max(1, lastSegment - 3), hi = min(n, lastSegment + 400)
        var found = lo < hi ? project(lo..<hi) : nil
        if found == nil || found!.dist > 80 { found = project(1..<n) ?? found }
        if let f = found {
            if f.dist > Self.offRouteMeters {
                // Don't advance along the line from a position that isn't on it: a loop/overpass
                // projection onto a later segment would otherwise skip every turn in between.
                offRouteCount += 1
            } else {
                offRouteCount = 0
                lastSegment = f.seg
                alongRoute = max(alongRoute, f.along)   // never slides backward on GPS jitter
            }
        }
        while stepIndex < steps.count, steps[stepIndex].offset <= alongRoute + 5 { stepIndex += 1 }
        if stepIndex < steps.count {
            nextTurn = steps[stepIndex].instruction
            nextTurnMeters = max(0, steps[stepIndex].offset - alongRoute)
        } else {
            nextTurn = nil; nextTurnMeters = nil
        }
        remainingMeters = max(0, (cumulative.last ?? 0) - alongRoute) + (found?.dist ?? 0)
    }

    private static func cumulativeLengths(_ c: [CLLocationCoordinate2D]) -> [Double] {
        var out = [Double](repeating: 0, count: c.count)
        guard c.count > 1 else { return out }
        for i in 1..<c.count { out[i] = out[i - 1] + c[i - 1].distanceMeters(to: c[i]) }
        return out
    }

    /// "0.3 mi" / "500 ft" style distance for the next-turn banner.
    static func distanceLabel(_ meters: Double) -> String {
        let miles = meters / 1609.34
        if miles >= 0.2 { return String(format: "%.1f mi", miles) }
        let feet = Int((meters * 3.28084 / 50).rounded() * 50)
        return "\(max(feet, 50)) ft"
    }
}
