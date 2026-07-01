import Foundation
#if canImport(ActivityKit) && !os(macOS)
import ActivityKit

/// Shared model for the trip Live Activity (Lock Screen + Dynamic Island).
///
/// IMPORTANT: this same file must be a member of BOTH the app target and the widget-extension
/// target — the extension renders the UI from `ContentState`, the app pushes updates. It lives in
/// the app's source tree; add it to the extension target's membership when you create that target.
struct DriveActivityAttributes: ActivityAttributes {
    /// Live, changing values pushed as the drive progresses.
    struct ContentState: Codable, Hashable {
        var milesTraveled: Double
        var currentSpeed: Double          // mph
        var elapsedSeconds: Int
        /// Fraction of the way to the destination, 0…1 (nil when there's no destination).
        var progress: Double?
        /// Estimated arrival, for the "arriving 4:20 PM" line (nil when unknown).
        var eta: Date?
        /// Projected delay vs. the scheduled arrival, seconds (+ = late). Nil if not scheduled.
        var delaySeconds: Int?
        var destinationName: String?
    }

    /// Fixed for the life of the activity.
    var tripTitle: String
    var scheduledArrival: Date?
}
#endif
