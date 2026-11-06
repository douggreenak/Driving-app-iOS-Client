import Foundation
import CoreLocation
import MapKit
import Observation

/// One maneuver on the guide route ("Turn left onto Main St").
struct GuideStep {
    var instruction: String
    var start: CLLocationCoordinate2D
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

    /// Forget the route (leg changed, drive ended, diverted…).
    func clear() {
        coordinates = []; steps = []; nextTurn = nil; nextTurnMeters = nil; remainingMeters = nil
        lastFetchFrom = nil; stepIndex = 0
    }

    /// Force the next `refresh` to re-fetch even though the driver hasn't moved.
    func invalidate() { lastFetchFrom = nil }

    /// Fetch the fastest route to `tracker.destination` from the current location. Throttled: only
    /// re-routes after ~250 m of movement (MapKit rate limits), with a back-off after a failure.
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
        // A line whose start has drifted far from where we are is worse than none.
        if let first = coordinates.first, first.distanceMeters(to: from) > 800 { coordinates = []; steps = [] }
        guard !inFlight else { return }
        if let last = lastFetchFrom, from.distanceMeters(to: last) < 250 { return }
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
            steps = route.steps.compactMap { s in
                guard !s.instructions.isEmpty, s.polyline.pointCount > 0 else { return nil }
                return GuideStep(instruction: s.instructions, start: s.polyline.coordinates()[0])
            }
            stepIndex = 0
            tracker.appleMapsExpectedTravelTime = route.expectedTravelTime
            tracker.appleMapsTravelTimeFetchDate = Date()
            updateNextTurn(from: from)
        }
    }

    /// Advance past maneuvers already reached and publish the next one.
    func updateNextTurn(from here: CLLocationCoordinate2D?) {
        guard let here else { return }
        while stepIndex < steps.count, steps[stepIndex].start.distanceMeters(to: here) < 35 { stepIndex += 1 }
        if stepIndex < steps.count {
            nextTurn = steps[stepIndex].instruction
            nextTurnMeters = steps[stepIndex].start.distanceMeters(to: here)
        } else {
            nextTurn = nil; nextTurnMeters = nil
        }
        if coordinates.count >= 2 {
            // Remaining length ahead: from the polyline point nearest to us onward.
            var nearest = 0; var best = Double.greatestFiniteMagnitude
            for (i, c) in coordinates.enumerated() {
                let d = c.distanceMeters(to: here)
                if d < best { best = d; nearest = i }
            }
            var m = best
            if nearest + 1 < coordinates.count {
                for i in (nearest + 1)..<coordinates.count { m += coordinates[i - 1].distanceMeters(to: coordinates[i]) }
            }
            remainingMeters = m
        }
    }

    /// "0.3 mi" / "500 ft" style distance for the next-turn banner.
    static func distanceLabel(_ meters: Double) -> String {
        let miles = meters / 1609.34
        if miles >= 0.2 { return String(format: "%.1f mi", miles) }
        let feet = Int((meters * 3.28084 / 50).rounded() * 50)
        return "\(max(feet, 50)) ft"
    }
}
