import Foundation
import CoreLocation
import Observation

/// Records a drive at high resolution, persists every fix to disk for crash/coverage safety,
/// and (optionally) tracks live ETA & delay against a scheduled destination.
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    /// Created lazily the first time location is actually needed. Constructing a
    /// `CLLocationManager` and starting updates connects to the location daemon, which is slow
    /// on first use — doing it in `init` blocked the Track tab from appearing the first time.
    private var manager: CLLocationManager?
    private let logger = DriveLogger()

    var isTracking = false
    var points: [RecordedPoint] = []
    var currentSpeed: Double = 0          // mph
    var totalDistance: Double = 0         // meters
    var movingSeconds: Int = 0
    var maxSpeed: Double = 0              // mph
    var elapsedSeconds: Int = 0
    var currentLocation: CLLocationCoordinate2D?
    var currentCourse: Double = -1
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Increments on every accepted GPS fix. Views observe this (instead of only the latitude) so
    /// the follow camera, guide-route refresh, and Live Activity update once per fix — even when
    /// the latitude is unchanged (stationary, or travelling due east/west).
    var fixCount: Int = 0

    // Destination / schedule context (optional).
    var destination: CLLocationCoordinate2D?
    var destinationName: String?
    var scheduledDeparture: Date?
    var scheduledArrival: Date?
    var tripName: String?
    var plannedCategory: TripCategory = .other
    /// Who's paying, as a `PayerGroup.key` (see Models/PayerGroup.swift).
    var plannedPaidBy: String = PayerGroup.selfKey
    var plannedVehicleName: String?
    /// Intermediate stops carried from a scheduled drive so the recorded trip keeps them.
    var plannedStops: [RouteStop] = []

    // MARK: - Multi-leg driving
    //
    // A multi-stop drive is broken into legs. `legTargets` is the ordered list of navigation
    // targets *after* the start: [stop1, stop2, …, finalDestination]. The drive advances one leg
    // at a time — arriving at an intermediate stop pauses recording (the car is parked while you
    // run the errand) and the next "Start next leg" resumes toward the following target. Only the
    // final leg ends the whole drive. A simple A→B drive has a single target (or none) and behaves
    // exactly as before.

    /// Ordered leg targets after the start: intermediate stops then the final destination.
    var legTargets: [RouteStop] = []
    /// Index into `legTargets` of the leg currently being driven (0 = start → legTargets[0]).
    var currentLegIndex: Int = 0
    /// True while parked at an intermediate stop, between finishing one leg and starting the next.
    /// The session stays alive (`isTracking`) but point capture is suspended.
    var isPausedBetweenLegs: Bool = false
    /// Arrival timestamps recorded as each intermediate leg is completed (one per passed stop).
    var legArrivals: [Date] = []
    /// `points.count` captured at the moment each intermediate stop is reached — the boundary index
    /// that ends one leg and starts the next. Lets a finished multi-stop drive be split into one
    /// recorded trip per leg (separate, linked trips) instead of a single trip with pauses.
    var legPointBoundaries: [Int] = []
    /// The ultimate endpoint's display name, kept separately from `destinationName` (which tracks
    /// the *current* leg target) so the overall trip can always show where it ends.
    var finalDestinationName: String?
    /// Whether points are actively being captured right now. Distinct from `isTracking`: false while
    /// paused between legs, so a parked errand isn't recorded as a stationary blob.
    private(set) var isRecording = false

    var isMultiLeg: Bool { legTargets.count > 1 }
    var totalLegs: Int { max(legTargets.count, 1) }
    /// The leg target we're currently driving toward, if any.
    var currentLegTarget: RouteStop? {
        legTargets.indices.contains(currentLegIndex) ? legTargets[currentLegIndex] : nil
    }
    /// True on the last leg (or a simple single-destination / open drive) — the leg whose end
    /// finishes the whole drive.
    var isOnFinalLeg: Bool { legTargets.count <= 1 || currentLegIndex >= legTargets.count - 1 }
    /// Number of intermediate stops already reached.
    var reachedStopCount: Int { min(currentLegIndex, max(legTargets.count - 1, 0)) }
    /// Intermediate stops only (excludes the final destination) — what the saved trip stores.
    var intermediateStops: [RouteStop] { legTargets.count > 1 ? Array(legTargets.dropLast()) : [] }
    /// How many separate leg-trips this finished recording will be split into on save (1 for a
    /// simple A→B drive). Mirrors the boundary→segment split used at save time, INCLUDING the
    /// ≥2-points-per-leg rule, so the "Saved as N linked trips" banner matches what's persisted.
    var recordedLegCount: Int {
        var count = 0, prev = 0
        for b in legPointBoundaries where b > prev && b <= points.count {
            if b - prev >= 2 { count += 1 }
            prev = b
        }
        if points.count - prev >= 2 { count += 1 }
        return max(count, 1)
    }

    /// Distance (miles) and elapsed seconds of the most recently completed leg — the stretch between
    /// the last two recorded stop boundaries. Powers the "leg complete" recap shown while parked
    /// between legs, so each stop reads as its own finished trip rather than a pause. Nil until at
    /// least one intermediate stop has been reached.
    var lastLegStats: (miles: Double, seconds: Int)? {
        guard let end = legPointBoundaries.last, end >= 1, end <= points.count else { return nil }
        let start = legPointBoundaries.count >= 2 ? legPointBoundaries[legPointBoundaries.count - 2] : 0
        guard end - start >= 2 else { return nil }
        let leg = Array(points[start..<end])
        guard let first = leg.first, let last = leg.last else { return nil }
        var meters = 0.0
        for i in 1..<leg.count {
            let step = leg[i - 1].coordinate.distanceMeters(to: leg[i].coordinate)
            if step < 500 { meters += step }
        }
        return (meters / 1609.34, Int(last.t.timeIntervalSince(first.t)))
    }

    private(set) var startTime: Date?
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private var lastMovingSample: Date?

    /// MPG used for the live, incrementally-accumulated fuel estimate.
    var ratedMpg: Double?
    private(set) var accumulatedGallons: Double = 0

    /// Fired on every accepted GPS fix and every elapsed-second tick while tracking. Wired by
    /// `ActiveDriveController` to `pushLiveUpdate()` so the Live Activity/Watch broadcast keeps
    /// running from the model itself, not just from `ContentView`'s `.onChange(of: tracker.fixCount /
    /// elapsedSeconds)`. Those `.onChange` modifiers only fire when SwiftUI actually performs a view
    /// update, which it suspends while the app is backgrounded / the screen is locked — precisely
    /// the state a Live Activity exists for (phone in a cradle, screen off, still driving).
    /// Location fixes and the 1s timer keep arriving in the background (the app declares the
    /// `location` background mode), so without this the Lock Screen froze on whatever numbers were
    /// last pushed while the app was foregrounded, until the `staleDate` greyed it out.
    var onUpdate: (() -> Void)?
    /// Small rolling window of recent speeds for a responsive ETA without scanning the whole track.
    private var recentSpeeds: [(t: Date, mph: Double)] = []

    override init() {
        super.init()
    }

    /// Create + configure the location manager once. Cheap config only — no daemon work beyond
    /// constructing the manager.
    private func configureIfNeeded() {
        guard manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.activityType = .automotiveNavigation
        // Only enable background updates if the app actually declares the location background mode,
        // otherwise CoreLocation raises an assertion and crashes.
        if Self.backgroundLocationEnabled {
            m.allowsBackgroundLocationUpdates = true
            m.showsBackgroundLocationIndicator = true
        }
        m.pausesLocationUpdatesAutomatically = false
        manager = m
        authorizationStatus = m.authorizationStatus
    }

    /// Begin low-power idle updates so the map can show the user's dot. Call this from the view's
    /// `.task` (after first paint) so the first-use CoreLocation cost never blocks the Track tab.
    func activateIdle() {
        configureIfNeeded()
        if authorizationStatus == .notDetermined { manager?.requestAlwaysAuthorization() }
        if !isTracking { applyPowerProfile(tracking: false) }  // don't downgrade an active drive
        manager?.startUpdatingLocation()
    }

    /// High precision + every fix while driving; coarse + throttled when idle.
    private func applyPowerProfile(tracking: Bool) {
        guard let manager else { return }
        if tracking {
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
    }

    /// True when the app bundle declares the `location` background mode.
    private static let backgroundLocationEnabled: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }()

    func requestPermission() {
        configureIfNeeded()
        manager?.requestAlwaysAuthorization()
    }

    // MARK: - Multi-leg route setup & progression

    /// Configure a destination (and optional intermediate stops) before starting, so the drive
    /// advances stop-by-stop. The current navigation target becomes the first leg's target.
    func setRoute(stops: [RouteStop], finalDestination: CLLocationCoordinate2D, finalName: String?) {
        // Guard against Null Island: an intermediate stop created before its address was picked
        // (or a malformed one from the backend) defaults to (0, 0) — routing through it is how a
        // "nonexistent path" gets drawn, since MapKit will happily plot a course to it.
        guard finalDestination.isUsableCoordinate else { return }
        var targets = stops.filter(\.coordinate.isUsableCoordinate)
        targets.append(RouteStop(address: finalName ?? "Destination", coordinate: finalDestination))
        legTargets = targets
        currentLegIndex = 0
        legArrivals = []
        isPausedBetweenLegs = false
        finalDestinationName = finalName
        destination = targets[0].coordinate
        destinationName = targets[0].address
    }

    /// Add a stop while a drive is in progress. New stops are visited before the final destination
    /// but after everything already passed. With no route yet, the stop becomes the destination.
    func appendLiveStop(_ stop: RouteStop) {
        guard stop.coordinate.isUsableCoordinate else { return }
        if legTargets.isEmpty {
            legTargets = [stop]
            finalDestinationName = stop.address
        } else {
            legTargets.insert(stop, at: legTargets.count - 1)
        }
        if let t = currentLegTarget { destination = t.coordinate; destinationName = t.address }
        persistLegState()
    }

    /// Mark arrival at the current intermediate stop and pause before the next leg. No-op on the
    /// final leg (use `stopTracking()` there to end the drive).
    func arriveAtCurrentStop() {
        guard isMultiLeg, !isOnFinalLeg else { return }
        legArrivals.append(Date())
        // Close off this leg's recorded points so the finished drive can be split into per-leg trips.
        legPointBoundaries.append(points.count)
        currentLegIndex += 1
        isPausedBetweenLegs = true
        isRecording = false
        currentSpeed = 0
        applyPowerProfile(tracking: false)  // low-power idle while parked
        if let t = currentLegTarget { destination = t.coordinate; destinationName = t.address }
        persistLegState()
    }

    /// Resume recording toward the next leg's target after a pause at a stop.
    func startNextLeg() {
        guard isPausedBetweenLegs else { return }
        isPausedBetweenLegs = false
        isRecording = true
        // Don't bridge the parked gap into distance/moving time or teleport the fuel estimate.
        lastLocation = nil
        lastMovingSample = nil
        applyPowerProfile(tracking: true)
        manager?.startUpdatingLocation()
        persistLegState()
    }

    func startTracking() {
        configureIfNeeded()
        points = []
        totalDistance = 0
        elapsedSeconds = 0
        movingSeconds = 0
        maxSpeed = 0
        currentSpeed = 0
        accumulatedGallons = 0
        recentSpeeds = []
        lastLocation = nil
        lastMovingSample = nil
        startTime = Date()
        isTracking = true
        isRecording = true
        isPausedBetweenLegs = false
        legPointBoundaries = []

        logger.begin(meta: currentMeta())

        applyPowerProfile(tracking: true)
        manager?.startUpdatingLocation()

        startElapsedTimer()
    }

    private func startElapsedTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            self.onUpdate?()
        }
        // `Timer.scheduledTimer` schedules on `.default`, which the run loop stops servicing while a
        // `UIScrollView` (any `List`/`ScrollView`, e.g. scrolling the departures board while a drive
        // is minimized) is actively tracking a touch — the live elapsed-time HUD, and everything
        // downstream of `elapsedSeconds` (the Live Activity/Watch push driven by `ContentView`'s
        // `.onChange(of: tracker.elapsedSeconds)`), stalls for as long as the scroll gesture lasts.
        // `.common` keeps firing through both modes.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Snapshot of the drive's metadata for the crash-safe log (includes multi-leg progress so a
    /// recovered or resumed drive keeps its stops and knows which leg it was on).
    private func currentMeta() -> DriveLogger.Meta {
        DriveLogger.Meta(
            start: startTime ?? Date(),
            destinationName: destinationName,
            scheduledArrival: scheduledArrival,
            scheduledDeparture: scheduledDeparture,
            category: plannedCategory.rawValue,
            vehicleName: plannedVehicleName,
            tripName: tripName,
            paidBy: plannedPaidBy,
            finalDestinationName: finalDestinationName,
            legTargets: legTargets,
            currentLegIndex: currentLegIndex,
            legArrivals: legArrivals,
            isPaused: isPausedBetweenLegs,
            legPointBoundaries: legPointBoundaries
        )
    }

    /// Persist the current leg progress to the crash log so it survives a kill mid-drive.
    private func persistLegState() {
        guard isTracking else { return }
        logger.updateMeta(currentMeta())
    }

    func stopTracking() {
        isTracking = false
        isRecording = false
        isPausedBetweenLegs = false
        applyPowerProfile(tracking: false)  // back to low-power idle updates for the map
        manager?.startUpdatingLocation()
        timer?.invalidate()
        timer = nil
        currentSpeed = 0
        // NOTE: intentionally does NOT clear the crash log here. The summary sheet is shown next
        // (swipe-dismiss disabled), so keeping the NDJSON alive until Save/Discard means a crash
        // while the summary is open can still recover the drive. clearCrashLog() runs on Save/Discard.
    }

    /// Resume a drive that was interrupted (kill/force-quit) mid-route — replaying the recorded
    /// points to rebuild distance/fuel and restoring which leg it was on, so a multi-stop drive can
    /// be continued instead of restarted. Keeps appending to the same crash log.
    func resume(from rec: DriveLogger.Recovered) {
        configureIfNeeded()
        points = rec.points
        // Rebuild derived totals from the recovered track.
        totalDistance = 0; maxSpeed = 0; accumulatedGallons = 0; movingSeconds = 0
        recentSpeeds = []
        for i in points.indices {
            maxSpeed = max(maxSpeed, points[i].speed)
            guard i > 0 else { continue }
            let step = points[i - 1].coordinate.distanceMeters(to: points[i].coordinate)
            if step < 500 {
                totalDistance += step
                let segMph = max(0, (points[i - 1].speed + points[i].speed) / 2)
                accumulatedGallons += (step / 1609.34) / FuelModel.mpg(atMph: segMph, ratedMpg: ratedMpg ?? 25)
            }
            // Rebuild moving time with the same >3mph endpoint-average rule used at save time, so the
            // live "moving" HUD doesn't under-report after a resume.
            let segMph = (points[i].speed + points[i - 1].speed) / 2
            if segMph > 3 { movingSeconds += Int(points[i].t.timeIntervalSince(points[i - 1].t)) }
        }
        let m = rec.meta
        startTime = m.start
        elapsedSeconds = Int(Date().timeIntervalSince(m.start))
        destinationName = m.destinationName
        scheduledArrival = m.scheduledArrival
        scheduledDeparture = m.scheduledDeparture
        tripName = m.tripName
        plannedCategory = TripCategory(rawValue: m.category) ?? .other
        plannedPaidBy = m.paidBy
        plannedVehicleName = m.vehicleName
        finalDestinationName = m.finalDestinationName
        legTargets = m.legTargets
        currentLegIndex = m.currentLegIndex
        legArrivals = m.legArrivals
        legPointBoundaries = m.legPointBoundaries
        if let t = currentLegTarget { destination = t.coordinate }
        isTracking = true
        isPausedBetweenLegs = m.isPaused
        isRecording = !m.isPaused
        lastLocation = nil
        lastMovingSample = nil
        logger.reopen()
        applyPowerProfile(tracking: isRecording)
        manager?.startUpdatingLocation()
        startElapsedTimer()
    }

    /// Discard a finished/recovered session's crash log (called once it's been saved).
    func clearCrashLog() { logger.finish() }

    /// Wipe the finished drive's data so the Track tab returns to a clean idle state instead of
    /// lingering on the last trip's stale track, stats, and destination after we route away.
    func resetAfterFinish() {
        points = []
        totalDistance = 0
        elapsedSeconds = 0
        movingSeconds = 0
        maxSpeed = 0
        currentSpeed = 0
        accumulatedGallons = 0
        recentSpeeds = []
        lastLocation = nil
        lastMovingSample = nil
        startTime = nil
        destination = nil
        destinationName = nil
        scheduledDeparture = nil
        scheduledArrival = nil
        tripName = nil
        plannedCategory = .other
        plannedPaidBy = PayerGroup.selfKey
        plannedVehicleName = nil
        plannedStops = []
        legTargets = []
        currentLegIndex = 0
        isPausedBetweenLegs = false
        isRecording = false
        legArrivals = []
        legPointBoundaries = []
        finalDestinationName = nil
        appleMapsExpectedTravelTime = nil
        appleMapsTravelTimeFetchDate = nil
    }

    // MARK: - Derived values

    var distanceMiles: Double { totalDistance / 1609.34 }
    var durationMinutes: Int { elapsedSeconds / 60 }

    var avgSpeedMph: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return distanceMiles / (Double(elapsedSeconds) / 3600)
    }

    /// Average speed *while moving* — total distance over the time actually spent driving (excluding
    /// stops). Unlike `avgSpeedMph` (total-time average), this does NOT collapse toward zero the
    /// longer the car sits at a stop, so it's a stable basis for the live ETA.
    var movingAvgSpeedMph: Double {
        guard movingSeconds > 0, distanceMiles > 0 else { return 0 }
        return distanceMiles / (Double(movingSeconds) / 3600)
    }

    /// Speed used to project the live ETA. Deliberately NOT the instantaneous/current speed: at a
    /// stop the current speed falls to ~0, and dividing the remaining distance by it makes the
    /// projected arrival balloon a little more every second the car sits still. Instead we average
    /// only the recent *moving* samples (>3 mph — so idling GPS noise is ignored), and once the car
    /// has been stopped or crawling for the whole recent window we fall back to the trip's moving
    /// average, which stays put while parked. Before any driving has happened, assume 25 mph.
    var etaSpeedMph: Double {
        let recentMoving = recentSpeeds.map(\.mph).filter { $0 > 3 }
        if !recentMoving.isEmpty { return recentMoving.reduce(0, +) / Double(recentMoving.count) }
        let moving = movingAvgSpeedMph
        return moving > 3 ? moving : 25
    }

    var startCoordinate: CLLocationCoordinate2D? { points.first?.coordinate }
    var endCoordinate: CLLocationCoordinate2D? { points.last?.coordinate }

    func estimatedGallons(mpg: Double) -> Double {
        FuelModel.gallons(segments: FuelModel.segments(from: points), ratedMpg: mpg)
    }

    /// Straight-line miles remaining to the final destination — for a multi-leg drive this sums
    /// the remaining legs (here → current target → … → final), inflated slightly to approximate
    /// roads. Drives the overall trip ETA and the scheduled-arrival delay.
    var remainingMiles: Double? {
        guard let here = currentLocation else { return nil }
        if legTargets.isEmpty {
            guard let destination else { return nil }
            return here.distanceMeters(to: destination) / 1609.34 * 1.3
        }
        var meters = 0.0
        var prev = here
        for i in currentLegIndex..<legTargets.count {
            let c = legTargets[i].coordinate
            meters += prev.distanceMeters(to: c)
            prev = c
        }
        return meters / 1609.34 * 1.3
    }

    /// Straight-line miles to just the *current* leg's target (the next stop).
    var legRemainingMiles: Double? {
        guard let here = currentLocation, let t = currentLegTarget else { return nil }
        return here.distanceMeters(to: t.coordinate) / 1609.34 * 1.3
    }

     /// Apple Maps remaining travel time (in seconds) to destination, fetched fresh from the API.
     /// This represents the estimated time to drive the current route from current location to destination.
     var appleMapsExpectedTravelTime: TimeInterval?
     /// When this travel time was fetched (used to subtract elapsed time for the ETA).
     var appleMapsTravelTimeFetchDate: Date?

     private func eta(forMiles miles: Double?) -> Date? {
         guard let miles else { return nil }
         let now = Date()
         if miles < 0.05 { return now }
         return now.addingTimeInterval(miles / max(etaSpeedMph, 5) * 3600)
     }

     /// Overall arrival at the final destination, primarily using Apple Maps when available.
     var etaDate: Date? {
         guard let remaining = remainingMiles else { return nil }
         let now = Date()
         if remaining < 0.05 { return now }

         // Prefer Apple Maps travel time when available and fresh — but only on the final leg.
         // `appleMapsExpectedTravelTime` is fetched (in `LiveTrackingView.refreshEfficientRoute`) to
         // `destination`, which for a multi-leg drive is the CURRENT leg's stop, not the ultimate
         // destination (see `setRoute`/`arriveAtCurrentStop`). On an earlier leg that travel time is
         // only the drive to the next stop; using it here would report it as the whole trip's ETA —
         // showing "ETA (final)"/the Live Activity/the Watch minutes away when there are still legs
         // to go after this stop, and throwing off the on-time/delayed status computed from it.
         if isOnFinalLeg, let travelTime = appleMapsExpectedTravelTime, let fetchDate = appleMapsTravelTimeFetchDate {
             // Only trust Apple Maps data if it's less than 30 seconds old (still fresh)
             let age = now.timeIntervalSince(fetchDate)
             if age < 30 {
                 return now.addingTimeInterval(travelTime)
             }
         }

         // Fallback to speed-based projection
         return eta(forMiles: remaining)
     }

     /// Arrival at the current leg's target (the next stop).
     var legEtaDate: Date? {
         guard let remaining = legRemainingMiles else { return nil }
         let now = Date()
         if remaining < 0.05 { return now }
         
         // Prefer Apple Maps travel time when available and fresh
         if let travelTime = appleMapsExpectedTravelTime, let fetchDate = appleMapsTravelTimeFetchDate {
             let age = now.timeIntervalSince(fetchDate)
             if age < 30 {
                 return now.addingTimeInterval(travelTime)
             }
         }
         
         return eta(forMiles: remaining)
     }

    /// Seconds late (positive) or early (negative) vs. the scheduled arrival.
    var delaySeconds: Int? {
        guard let scheduledArrival, let etaDate else { return nil }
        return Int(etaDate.timeIntervalSince(scheduledArrival))
    }

    func formattedElapsed() -> String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Crash recovery

    /// A drive that was interrupted (crash/force-quit) and never saved, if any.
    static func recoverableSession() -> DriveLogger.Recovered? {
        DriveLogger.recover()
    }

    static func discardRecoverableSession() {
        DriveLogger().finish()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            let coord = location.coordinate
            currentLocation = coord
            if location.course >= 0 { currentCourse = location.course }

            // Capture EVERY valid fix while driving — including lower-accuracy ones in poor
            // coverage (their accuracy is stored so quality is known). Only a negative
            // horizontalAccuracy (an invalid fix with no real coordinate) is skipped.
            guard location.horizontalAccuracy >= 0, CLLocationCoordinate2DIsValid(coord) else { continue }
            fixCount &+= 1  // tick on every valid fix so views refresh regardless of heading
            // Placed before the recording guard below so a fix arriving while paused between legs
            // still pushes (e.g. the Live Activity's "Parked at a stop" state) — `onUpdate` itself
            // no-ops via `pushLiveUpdate`'s own `tracker.isTracking` check when nothing's actually
            // under way, so the `isTracking` guard here is purely to skip the call while idle before
            // a drive even starts (map-dot-only fixes from `activateIdle()`).
            if isTracking { onUpdate?() }

            let mph = location.speed >= 0 ? location.speed * 2.23694 : 0
            if location.speed >= 0 {
                // Only reflect speed while actually recording — parked between legs (or idle before
                // a drive) shouldn't show GPS-noise speed on the HUD or inflate the drive's max.
                currentSpeed = isRecording ? mph : 0
                if isRecording { maxSpeed = max(maxSpeed, mph) }
            }

            // Capture points only while recording a leg. Paused (between legs) keeps the session
            // alive for the map/ETA without recording a stationary blob at the stop.
            guard isTracking, isRecording else { continue }

            let point = RecordedPoint(
                t: location.timestamp,
                coordinate: coord,
                speed: max(0, mph),
                course: location.course,
                accuracy: location.horizontalAccuracy,
                altitude: location.altitude * 3.28084  // meters → feet
            )
            points.append(point)
            logger.append(point)

            // Rolling 60s speed window for the ETA (kept tiny, no full-track scans).
            recentSpeeds.append((location.timestamp, max(0, mph)))
            let cutoff = location.timestamp.addingTimeInterval(-60)
            while let first = recentSpeeds.first, first.t < cutoff { recentSpeeds.removeFirst() }

            if let last = lastLocation {
                let step = location.distance(from: last)
                // Reject teleport spikes from bad fixes.
                if step < 500 {
                    totalDistance += step
                    // Accumulate the speed-aware fuel estimate incrementally (O(1) per fix)
                    // instead of re-integrating the whole track on every UI refresh.
                    let prevMph = last.speed >= 0 ? last.speed * 2.23694 : mph
                    let segMph = max(0, (prevMph + mph) / 2)
                    accumulatedGallons += (step / 1609.34) / FuelModel.mpg(atMph: segMph, ratedMpg: ratedMpg ?? 25)
                }
                // Count an interval as "moving" using the interval's AVERAGE speed — matches
                // `TripStore.movingSeconds`'s save-time rule exactly (`(pts[i].speed +
                // pts[i-1].speed) / 2 > 3`). This used to require BOTH endpoints individually above
                // the threshold, a stricter rule: an accel-from-stop or decel-to-stop interval (e.g.
                // 0 → 10 mph — average 5, comfortably "moving", but the 0 mph endpoint fails the
                // both-ends test) was excluded live but included once the trip was saved, so the
                // live HUD's moving-time readout (and its `movingAvgSpeedMph`/`etaSpeedMph` fallback
                // while parked) silently disagreed with the persisted `DriveTrip.movingSeconds` for
                // any drive with real stop-and-go — visibly jumping on `resume()` too, since recovery
                // already rebuilds with the save-time (average) rule.
                let prevMph = last.speed >= 0 ? last.speed * 2.23694 : 0
                if (mph + prevMph) / 2 > 3, let prev = lastMovingSample {
                    movingSeconds += Int(location.timestamp.timeIntervalSince(prev).rounded())
                }
                lastMovingSample = location.timestamp
            } else {
                lastMovingSample = location.timestamp
            }
            lastLocation = location
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - Crash-safe drive logger

/// Streams every recorded fix to disk so a crash, force-quit, or extended no-coverage stretch
/// never loses the drive. Uses an append-only NDJSON file plus a small metadata sidecar.
final class DriveLogger {
    struct Meta: Codable {
        var start: Date
        var destinationName: String?
        var scheduledArrival: Date?
        var scheduledDeparture: Date? = nil
        var category: String
        var vehicleName: String?
        var tripName: String? = nil
        /// Who pays for this drive's gas — the app's core concept — so recovery/resume keeps it.
        /// A `PayerGroup.key`.
        var paidBy: String = PayerGroup.selfKey
        // Multi-leg progress, so a recovered/resumed drive keeps its stops and current leg.
        var finalDestinationName: String? = nil
        var legTargets: [RouteStop] = []
        var currentLegIndex: Int = 0
        var legArrivals: [Date] = []
        var isPaused: Bool = false
        /// Per-leg point-count boundaries so a recovered multi-stop drive still splits into legs.
        var legPointBoundaries: [Int] = []
    }

    struct Recovered {
        var meta: Meta
        var points: [RecordedPoint]
    }

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var pointsURL: URL { dir.appendingPathComponent("active-drive.ndjson") }
    private static var metaURL: URL { dir.appendingPathComponent("active-drive.meta.json") }

    private var handle: FileHandle?
    private let encoder = JSONEncoder()

    func begin(meta: Meta) {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.pointsURL)
        fm.createFile(atPath: Self.pointsURL.path, contents: nil)
        if let data = try? encoder.encode(meta) { try? data.write(to: Self.metaURL) }
        handle = try? FileHandle(forWritingTo: Self.pointsURL)
    }

    /// Rewrite just the metadata sidecar (leg progress etc.) without touching the point stream.
    func updateMeta(_ meta: Meta) {
        if let data = try? encoder.encode(meta) { try? data.write(to: Self.metaURL) }
    }

    /// Re-open the existing point stream for appending (used when resuming an interrupted drive)
    /// instead of truncating it the way `begin` does.
    func reopen() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.pointsURL.path) {
            fm.createFile(atPath: Self.pointsURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Self.pointsURL)
    }

    func append(_ point: RecordedPoint) {
        guard let handle, var data = try? encoder.encode(point) else { return }
        data.append(0x0A)  // newline
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    func finish() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: Self.pointsURL)
        try? FileManager.default.removeItem(at: Self.metaURL)
    }

    static func recover() -> Recovered? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pointsURL.path),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
              let raw = try? String(contentsOf: pointsURL, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        let points = raw.split(separator: "\n").compactMap {
            try? decoder.decode(RecordedPoint.self, from: Data($0.utf8))
        }
        guard points.count >= 2 else { return nil }
        return Recovered(meta: meta, points: points)
    }
}

extension DriveLogger.Meta {
    enum CodingKeys: String, CodingKey {
        case start, destinationName, scheduledArrival, scheduledDeparture, category, vehicleName,
             tripName, paidBy, finalDestinationName, legTargets, currentLegIndex, legArrivals,
             isPaused, legPointBoundaries
    }

    /// Tolerant decode: synthesized `Decodable` throws `keyNotFound` for any missing key regardless
    /// of the property's default, so a crash log written by an *older* build (lacking newer fields
    /// like `legPointBoundaries`) would fail to decode — silently losing an in-progress drive on
    /// update. Decode every evolvable field with `decodeIfPresent` + a fallback so recovery is
    /// robust across versions (goal: crash-/coverage-proof logging).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        destinationName = try c.decodeIfPresent(String.self, forKey: .destinationName)
        scheduledArrival = try c.decodeIfPresent(Date.self, forKey: .scheduledArrival)
        scheduledDeparture = try c.decodeIfPresent(Date.self, forKey: .scheduledDeparture)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? TripCategory.other.rawValue
        vehicleName = try c.decodeIfPresent(String.self, forKey: .vehicleName)
        tripName = try c.decodeIfPresent(String.self, forKey: .tripName)
        paidBy = try c.decodeIfPresent(String.self, forKey: .paidBy) ?? PayerGroup.selfKey
        finalDestinationName = try c.decodeIfPresent(String.self, forKey: .finalDestinationName)
        legTargets = try c.decodeIfPresent([RouteStop].self, forKey: .legTargets) ?? []
        currentLegIndex = try c.decodeIfPresent(Int.self, forKey: .currentLegIndex) ?? 0
        legArrivals = try c.decodeIfPresent([Date].self, forKey: .legArrivals) ?? []
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        legPointBoundaries = try c.decodeIfPresent([Int].self, forKey: .legPointBoundaries) ?? []
    }
}
