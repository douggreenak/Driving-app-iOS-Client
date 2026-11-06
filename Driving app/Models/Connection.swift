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
