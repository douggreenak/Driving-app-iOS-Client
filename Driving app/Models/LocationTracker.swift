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

    // Destination / schedule context (optional).
    var destination: CLLocationCoordinate2D?
    var destinationName: String?
    var scheduledDeparture: Date?
    var scheduledArrival: Date?
    var tripName: String?
    var plannedCategory: TripCategory = .other
    var plannedPaidBy: PaidBy = .myself
    var plannedVehicleName: String?

    private(set) var startTime: Date?
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private var lastMovingSample: Date?

    /// MPG used for the live, incrementally-accumulated fuel estimate.
    var ratedMpg: Double?
    private(set) var accumulatedGallons: Double = 0
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

        logger.begin(start: startTime!,
                     destinationName: destinationName,
                     scheduledArrival: scheduledArrival,
                     category: plannedCategory,
                     vehicleName: plannedVehicleName)

        applyPowerProfile(tracking: true)
        manager?.startUpdatingLocation()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(start))
        }
    }

    func stopTracking() {
        isTracking = false
        applyPowerProfile(tracking: false)  // back to low-power idle updates for the map
        manager?.startUpdatingLocation()
        timer?.invalidate()
        timer = nil
        currentSpeed = 0
        logger.finish()
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
        plannedPaidBy = .myself
        plannedVehicleName = nil
    }

    // MARK: - Derived values

    var distanceMiles: Double { totalDistance / 1609.34 }
    var durationMinutes: Int { elapsedSeconds / 60 }

    var avgSpeedMph: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return distanceMiles / (Double(elapsedSeconds) / 3600)
    }

    /// Average speed over roughly the last minute, for a responsive live ETA. Reads a small
    /// rolling window instead of scanning the whole (growing) track on every access.
    var recentAvgSpeedMph: Double {
        let recent = recentSpeeds.map(\.mph).filter { $0 > 0 }
        if !recent.isEmpty { return recent.reduce(0, +) / Double(recent.count) }
        return avgSpeedMph > 1 ? avgSpeedMph : 25
    }

    var startCoordinate: CLLocationCoordinate2D? { points.first?.coordinate }
    var endCoordinate: CLLocationCoordinate2D? { points.last?.coordinate }

    func estimatedGallons(mpg: Double) -> Double {
        FuelModel.gallons(segments: FuelModel.segments(from: points), ratedMpg: mpg)
    }

    /// Straight-line miles remaining to the destination (inflated slightly to approximate roads).
    var remainingMiles: Double? {
        guard let destination, let here = currentLocation else { return nil }
        return here.distanceMeters(to: destination) / 1609.34 * 1.3
    }

    var etaDate: Date? {
        guard let remainingMiles else { return nil }
        let now = Date()
        if remainingMiles < 0.05 { return now }
        let hours = remainingMiles / max(recentAvgSpeedMph, 5)
        return now.addingTimeInterval(hours * 3600)
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

            let mph = location.speed >= 0 ? location.speed * 2.23694 : 0
            if location.speed >= 0 {
                currentSpeed = mph
                maxSpeed = max(maxSpeed, mph)
            }

            guard isTracking else { continue }

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
                // Count an interval as "moving" only when both ends are above the idle threshold,
                // so time spent stopped (then resuming) isn't folded into moving time.
                let prevMph = last.speed >= 0 ? last.speed * 2.23694 : 0
                if mph > 3, prevMph > 3, let prev = lastMovingSample {
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
        var category: String
        var vehicleName: String?
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

    func begin(start: Date, destinationName: String?, scheduledArrival: Date?, category: TripCategory, vehicleName: String?) {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.pointsURL)
        fm.createFile(atPath: Self.pointsURL.path, contents: nil)
        let meta = Meta(start: start, destinationName: destinationName,
                        scheduledArrival: scheduledArrival, category: category.rawValue,
                        vehicleName: vehicleName)
        if let data = try? encoder.encode(meta) { try? data.write(to: Self.metaURL) }
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
