import Foundation

/// Speed-aware fuel economy model.
///
/// Real fuel economy is not constant: it is poor in stop-and-go crawling, peaks in the
/// mid-speed range (~45–55 mph), and falls off at highway speed as aerodynamic drag grows.
/// Instead of `gallons = distance / averageMpg`, we estimate the MPG the car actually gets
/// at each segment's speed and integrate fuel use segment by segment.
enum FuelModel {

    /// Fraction of a vehicle's rated (best/combined) MPG achieved at a given speed in mph.
    /// Anchored to a realistic efficiency curve and linearly interpolated between anchors.
    private static let anchors: [(mph: Double, frac: Double)] = [
        (0, 0.30), (10, 0.55), (20, 0.74), (30, 0.87), (40, 0.96),
        (50, 1.00), (55, 1.00), (60, 0.95), (65, 0.89), (70, 0.82),
        (80, 0.70), (90, 0.58), (100, 0.48),
    ]

    /// Relative efficiency (fraction of rated MPG) at `mph`.
    static func efficiencyFraction(atMph mph: Double) -> Double {
        let v = max(0, mph)
        if v <= anchors.first!.mph { return anchors.first!.frac }
        if v >= anchors.last!.mph { return anchors.last!.frac }
        for i in 1..<anchors.count {
            let a = anchors[i - 1], b = anchors[i]
            if v <= b.mph {
                let t = (v - a.mph) / (b.mph - a.mph)
                return a.frac + t * (b.frac - a.frac)
            }
        }
        return anchors.last!.frac
    }

    /// Effective MPG at `mph` for a car whose rated/best MPG is `ratedMpg`.
    static func mpg(atMph mph: Double, ratedMpg: Double) -> Double {
        max(1, ratedMpg * efficiencyFraction(atMph: mph))
    }

    /// A single piece of a drive: how far you went and how fast you were going.
    struct Segment {
        var miles: Double
        var mph: Double
    }

    /// Total gallons used over a set of segments, using the speed-aware MPG for each.
    static func gallons(segments: [Segment], ratedMpg: Double) -> Double {
        guard ratedMpg > 0 else { return 0 }
        return segments.reduce(0) { sum, seg in
            guard seg.miles > 0 else { return sum }
            return sum + seg.miles / mpg(atMph: seg.mph, ratedMpg: ratedMpg)
        }
    }

    /// Build segments from recorded points (consecutive points → one segment whose speed is
    /// the average of the two endpoints, and whose distance is the geodesic gap between them).
    static func segments(from points: [RecordedPoint]) -> [Segment] {
        guard points.count >= 2 else { return [] }
        var out: [Segment] = []
        out.reserveCapacity(points.count - 1)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let meters = a.coordinate.distanceMeters(to: b.coordinate)
            // Reject teleport spikes from bad GPS fixes, matching how live distance is
            // accumulated — otherwise a single glitch inflates the fuel estimate and makes it
            // disagree with the trip's measured distance.
            guard meters < 500 else { continue }
            let miles = meters / 1609.34
            guard miles > 0 else { continue }
            // Prefer measured GPS speed; fall back to distance/time if speed is missing.
            var mph = (a.speed + b.speed) / 2
            if mph <= 0 {
                let dt = b.t.timeIntervalSince(a.t)
                // Require a sane interval so a sub-second gap can't imply thousands of mph.
                if dt > 0.5 { mph = (miles / (dt / 3600)) }
            }
            out.append(Segment(miles: miles, mph: max(0, mph)))
        }
        return out
    }

    /// Distance-weighted breakdown of fuel use by speed band, for the trip-detail page.
    struct Band: Identifiable {
        var id: String { label }
        var label: String
        var miles: Double
        var gallons: Double
    }

    private static let bands: [(label: String, lo: Double, hi: Double)] = [
        ("0–25 mph", 0, 25), ("25–45 mph", 25, 45),
        ("45–65 mph", 45, 65), ("65+ mph", 65, .infinity),
    ]

    static func bandBreakdown(segments: [Segment], ratedMpg: Double) -> [Band] {
        bands.map { band in
            let segs = segments.filter { $0.mph >= band.lo && $0.mph < band.hi }
            return Band(
                label: band.label,
                miles: segs.reduce(0) { $0 + $1.miles },
                gallons: gallons(segments: segs, ratedMpg: ratedMpg)
            )
        }
        .filter { $0.miles > 0.01 }
    }
}
