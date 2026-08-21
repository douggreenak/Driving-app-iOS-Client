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
    /// How far ahead each push marks its content stale. Without this (it used to be `nil` on every
    /// push) the OS never dims/greys a frozen activity — so if the pushing side ever genuinely stops
    /// (e.g. this exact class of bug: the periodic-push wiring silently missing), the Lock Screen
    /// keeps showing the last numbers as if they were still live, indefinitely, with no visual cue
    /// anything's wrong. A stale marker a little past our own push cadence means a real freeze still
    /// shows the system's built-in "not current" treatment.
    private static let staleAfter: TimeInterval = 90

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
                                         content: .init(state: state, staleDate: Date().addingTimeInterval(staleAfter)))
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
        Task { await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(staleAfter))) }
    }

    /// Push right away for changes a driver would notice even between throttle windows.
    private static func isMeaningfulChange(from a: DriveActivityAttributes.ContentState?,
                                           to b: DriveActivityAttributes.ContentState) -> Bool {
        guard let a else { return true }
        if a.destinationName != b.destinationName { return true }  // advanced a leg
        if Int(a.milesTraveled) != Int(b.milesTraveled) { return true }  // crossed a mile
        let da = (a.delaySeconds ?? 0) / 60, db = (b.delaySeconds ?? 0) / 60
        if da != db { return true }  // delay minute changed
        // Parked ↔ moving flips the whole "Parked at a stop" line — without this a "Start Next Leg"
        // tap could sit under the 3s throttle and leave the Lock Screen reading "Parked" for a few
        // seconds after the car is already moving again.
        if a.isPaused != b.isPaused { return true }
        return false
    }

    /// True while a just-finished drive's terminal frame is deliberately being held on screen (see
    /// `endWithFinal`) — lets `end()` tell "nothing to end" apart from "something IS ending, on
    /// purpose, leave it alone" when it falls through to `endOrphaned()`.
    private static var finalizing = false

    /// Push a final state (e.g. "Arrived, 42.3 mi, on time") and end the activity a couple of
    /// minutes later, so the widget shows a real terminal frame instead of just vanishing —
    /// `dismissalPolicy: .immediate` in `end()` skipped straight past whatever was last on screen.
    static func endWithFinal(_ state: DriveActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        finalizing = true
        Task {
            await activity.update(.init(state: state, staleDate: nil))
            try? await Task.sleep(for: .seconds(1))
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(120)))
            finalizing = false
        }
    }

    /// End and dismiss the activity when the drive stops. Falls back to sweeping every orphaned
    /// activity of ours when there's no in-memory `activity` to end directly — e.g. the drive was
    /// recovered (Save/Discard) after a relaunch, so nothing in THIS process ever called `start()`
    /// to populate it, and without this fallback the previous process's activity would never end.
    /// Skips that sweep while `endWithFinal`'s terminal frame is still deliberately holding — e.g.
    /// `ActiveDriveController.clear()` (called right after `endWithFinal` when the summary is saved
    /// or discarded) used to have this immediately sweep away the very "Arrived" frame that was
    /// supposed to linger for two minutes, so it always vanished the instant the summary closed.
    static func end() {
        guard let activity else {
            if !finalizing { Task { await endOrphaned() } }
            return
        }
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
    ///
    /// Deliberately excludes THIS process's own `activity` (by id) — `ContentView` calls this
    /// opportunistically on every tab switch/foreground while `LocationTracker.recoverableSession()`
    /// reads nil, which is also true for the first second or two of a brand-new drive (the crash log
    /// only becomes "recoverable" once 2 points have landed). Without the exclusion, a tab switch in
    /// that window ended the activity that had just started — and left `start()`'s `activity == nil`
    /// guard permanently unable to request a new one for the rest of the process, since the static
    /// reference was never cleared to match.
    static func endOrphaned() async {
        let mine = activity?.id
        for orphan in Activity<DriveActivityAttributes>.activities where orphan.id != mine {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
