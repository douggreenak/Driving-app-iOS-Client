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
        /// True while parked at an intermediate stop on a multi-leg drive — the widget shows
        /// "Parked at Stop N" instead of a speed/ETA that would otherwise read as frozen/wrong
        /// while the car genuinely isn't moving toward anything right now.
        var isPaused: Bool = false
        /// Mirrors `DriveActivityAttributes.tripTitle`/`scheduledArrival` below. `ActivityAttributes`
        /// is fixed for the activity's whole life, but a drive's title and schedule aren't: an
        /// ad-hoc drive that later gains a destination (or a "Go to" whose ETA resolves after the
        /// activity already started) needs to update these too, which only `ContentState` can do.
        /// The widget reads these in preference to the attribute fields.
        var tripTitle: String?
        var scheduledArrival: Date?
    }

    /// Initial values only — see `ContentState.tripTitle`/`scheduledArrival` for why the live values
    /// live there instead. Kept here too since `Activity.request` requires *something* at creation.
    var tripTitle: String
    var scheduledArrival: Date?
}
#endif
