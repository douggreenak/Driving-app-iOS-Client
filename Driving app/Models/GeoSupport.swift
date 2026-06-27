import Foundation
import CoreLocation

/// A single recorded GPS fix. Plain value type (not a SwiftData model) so it is cheap to
/// append at high frequency while driving and easy to serialize for crash-safe logging.
struct RecordedPoint: Codable, Equatable {
    var t: Date
    var lat: Double
    var lng: Double
    /// Instantaneous speed in mph (>= 0; 0 if the fix had no valid speed).
    var speed: Double
    /// Course over ground in degrees, or -1 if invalid.
    var course: Double
    /// Horizontal accuracy in meters.
    var accuracy: Double
    /// Altitude in feet above sea level.
    var altitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    init(t: Date, coordinate: CLLocationCoordinate2D, speed: Double, course: Double, accuracy: Double, altitude: Double = 0) {
        self.t = t
        self.lat = coordinate.latitude
        self.lng = coordinate.longitude
        self.speed = speed
        self.course = course
        self.accuracy = accuracy
        self.altitude = altitude
    }

    enum CodingKeys: String, CodingKey { case t, lat, lng, speed, course, accuracy, altitude }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Date.self, forKey: .t)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        speed = try c.decode(Double.self, forKey: .speed)
        course = try c.decode(Double.self, forKey: .course)
        accuracy = try c.decode(Double.self, forKey: .accuracy)
        // Tolerate crash logs written before altitude existed.
        altitude = try c.decodeIfPresent(Double.self, forKey: .altitude) ?? 0
    }
}

extension CLLocationCoordinate2D {
    func distanceMeters(to other: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

/// Simple local-tangent-plane projection so we can do fast planar geometry (point-to-segment
/// projection for map matching) at city/region scale without expensive geodesic math.
struct LocalPlane {
    let refLat: Double
    let refLng: Double
    private let mPerDegLat: Double
    private let mPerDegLng: Double

    init(reference: CLLocationCoordinate2D) {
        refLat = reference.latitude
        refLng = reference.longitude
        mPerDegLat = 111_320
        mPerDegLng = 111_320 * cos(reference.latitude * .pi / 180)
    }

    /// Project to meters east/north of the reference point.
    func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((c.longitude - refLng) * mPerDegLng, (c.latitude - refLat) * mPerDegLat)
    }

    func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: refLat + y / mPerDegLat,
                               longitude: refLng + x / mPerDegLng)
    }
}

enum Polyline {
    /// Encode coordinates as a Google-style encoded polyline (precision 5), suitable for the
    /// web backend's `routeEncoded` field.
    static func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var result = ""
        var prevLat = 0, prevLng = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded())
            let lng = Int((c.longitude * 1e5).rounded())
            result += encode(lat - prevLat)
            result += encode(lng - prevLng)
            prevLat = lat
            prevLng = lng
        }
        return result
    }

    private static func encode(_ value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var out = ""
        while v >= 0x20 {
            out.append(Character(UnicodeScalar((0x20 | (v & 0x1f)) + 63)!))
            v >>= 5
        }
        out.append(Character(UnicodeScalar(v + 63)!))
        return out
    }
}
