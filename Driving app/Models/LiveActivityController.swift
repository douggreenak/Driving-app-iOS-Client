import Foundation
#if canImport(ActivityKit) && !os(macOS)
import ActivityKit

/// Starts, updates, and ends the drive Live Activity. All calls are safe no-ops when Live
/// Activities are disabled or the widget extension isn't installed, so the app builds and runs
/// with or without the extension target present.
@MainActor
enum LiveActivityController {
    private static var activity: Activity<DriveActivityAttributes>?
    private static var lastPush: Date = .distantPast
    private static var lastState: DriveActivityAttributes.ContentState?
    /// Minimum spacing between routine pushes. CoreLocation delivers several fixes per second while
    /// driving; ActivityKit budgets frequent updates and will throttle then stop delivering, freezing
    /// the Lock Screen. ~3s keeps us comfortably under budget while staying live.
    private static let minInterval: TimeInterval = 3

    /// Begin a Live Activity for a drive. Ignored if one is already running or the user has Live
    /// Activities turned off.
    static func start(title: String, scheduledArrival: Date?, state: DriveActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        // Sweep away anything left over from a prior process (e.g. a force-quit mid-drive never got
        // to call `end()`) so a stale, frozen activity doesn't linger alongside this new one. Snapshot
        // the orphan ids *before* requesting our own activity below — the sweep runs as a
        // fire-and-forget background Task, and by the time it actually executes our new activity may
        // already be in `Activity<DriveActivityAttributes>.activities` too; ending everything found
        // *then* would end the one we just started.
        let orphanIDs = Set(Activity<DriveActivityAttributes>.activities.map(\.id))
        if !orphanIDs.isEmpty {
            Task {
                for a in Activity<DriveActivityAttributes>.activities where orphanIDs.contains(a.id) {
                    await a.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        let attributes = DriveActivityAttributes(tripTitle: title, scheduledArrival: scheduledArrival)
        activity = try? Activity.request(attributes: attributes,
                                         content: .init(state: state, staleDate: nil))
        lastPush = Date()
        lastState = state
    }

    /// Push the latest trip numbers to the running activity, throttled to avoid ActivityKit's
    /// update budget. A meaningful change (crossed a mile, delay flipped, arrived at a stop) pushes
    /// immediately; otherwise routine updates are spaced out.
    static func update(_ state: DriveActivityAttributes.ContentState) {
        guard let activity else { return }
        let now = Date()
        if now.timeIntervalSince(lastPush) < minInterval, !isMeaningfulChange(from: lastState, to: state) {
            return
        }
        lastPush = now
        lastState = state
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// Push right away for changes a driver would notice even between throttle windows.
    private static func isMeaningfulChange(from a: DriveActivityAttributes.ContentState?,
                                           to b: DriveActivityAttributes.ContentState) -> Bool {
        guard let a else { return true }
        if a.destinationName != b.destinationName { return true }  // advanced a leg
        if Int(a.milesTraveled) != Int(b.milesTraveled) { return true }  // crossed a mile
        let da = (a.delaySeconds ?? 0) / 60, db = (b.delaySeconds ?? 0) / 60
        if da != db { return true }  // delay minute changed
        return false
    }

    /// End and dismiss the activity when the drive stops.
    static func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends every Live Activity of ours left running from a previous process — e.g. the app was
    /// force-quit mid-drive, so `end()` never ran: the in-memory `activity` reference above was lost
    /// on relaunch, but the OS-level activity itself keeps showing on the Lock Screen/Dynamic Island
    /// with stale, frozen numbers (potentially until it auto-expires) unless something proactively
    /// ends it. Intended for app launch, when there's no drive actually being recovered — safe to
    /// call any time, including when nothing is orphaned.
    static func endOrphaned() async {
        for orphan in Activity<DriveActivityAttributes>.activities {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
