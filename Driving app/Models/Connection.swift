import Foundation

/// Rules for *connections*: a short stop between two legs of a drive (a quick run into the house,
/// a coffee stop) that should read as one journey with a layover, the way a flight tracker shows a
/// connection — as opposed to a long stop that is really the end of one trip and the start of
/// another.
enum Connection {
    /// A stop shorter than this is a connection; this long or longer ends the trip.
    static let maxLayover: TimeInterval = 3 * 3600

    static func isConnection(_ seconds: TimeInterval) -> Bool { seconds < maxLayover }
    static func isConnection(_ seconds: Int) -> Bool { isConnection(TimeInterval(seconds)) }

    /// Compact duration for a layover: "45s", "12m", "1h 5m".
    static func label(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}

extension Connection {
    /// The connection (layover) between two trips — `earlier` ended where `later` began (within
    /// ~250 m) and the stop was shorter than `maxLayover`. Works for ANY pair of trips, not just legs
    /// recorded as one journey: driving to the shop, then home, with a short stop in between is a
    /// connection however the two trips were saved. Nil when they aren't connected.
    static func gap(from earlier: DriveTrip, to later: DriveTrip) -> Int? {
        let seconds = later.date.timeIntervalSince(earlier.endDate)
        guard seconds >= 0, isConnection(seconds) else { return nil }
        guard earlier.endCoordinate.distanceMeters(to: later.startCoordinate) < 250 else { return nil }
        return Int(seconds)
    }
}
