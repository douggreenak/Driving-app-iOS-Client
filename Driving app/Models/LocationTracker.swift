import Foundation
import CoreLocation
import Observation

@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var isTracking = false
    var routeCoordinates: [CLLocationCoordinate2D] = []
    var currentSpeed: Double = 0
    var totalDistance: Double = 0
    var elapsedSeconds: Int = 0
    var currentLocation: CLLocationCoordinate2D?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private var startTime: Date?
    private var timer: Timer?
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.allowsBackgroundLocationUpdates = false
        manager.activityType = .automotiveNavigation
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startTracking() {
        routeCoordinates = []
        totalDistance = 0
        elapsedSeconds = 0
        currentSpeed = 0
        lastLocation = nil
        startTime = Date()
        isTracking = true

        manager.startUpdatingLocation()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(start))
        }
    }

    func stopTracking() {
        isTracking = false
        manager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        currentSpeed = 0
    }

    var distanceMiles: Double {
        totalDistance / 1609.34
    }

    var durationMinutes: Int {
        elapsedSeconds / 60
    }

    var avgSpeedMph: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return distanceMiles / (Double(elapsedSeconds) / 3600)
    }

    var startCoordinate: CLLocationCoordinate2D? {
        routeCoordinates.first
    }

    var endCoordinate: CLLocationCoordinate2D? {
        routeCoordinates.last
    }

    func estimatedGallons(mpg: Double) -> Double {
        guard mpg > 0 else { return 0 }
        return distanceMiles / mpg
    }

    func formattedElapsed() -> String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 50 else { continue }

            let coord = location.coordinate
            routeCoordinates.append(coord)
            currentLocation = coord

            if location.speed >= 0 {
                currentSpeed = location.speed * 2.23694
            }

            if let last = lastLocation {
                totalDistance += location.distance(from: last)
            }
            lastLocation = location
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
