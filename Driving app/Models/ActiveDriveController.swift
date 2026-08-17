import Foundation
import Observation
#if canImport(ActivityKit) && !os(macOS)
import ActivityKit
#endif

/// Owns the one active (or most-recently-active) drive's `LocationTracker` and how it's currently
/// presented, for the app's whole lifetime — instantiated once by `ContentView` and shared via
/// `.environment(_:)`. This is what makes "minimize" possible: today `LiveTrackingView` owns its
/// tracker as `@State`, so dismissing its full-screen cover deallocates it — there's nothing left to
/// reopen. Lifting the tracker up here means dismissing the cover (minimizing) no longer stops the
/// drive; the same tracker instance is just handed back to a freshly-presented `LiveTrackingView`
/// when the user taps the minimized pill to restore it.
///
/// This is also where the *recurring* Live Activity / Watch-live-broadcast pushes live, instead of in
/// `LiveTrackingView` itself: those used to fire from the view's own `.onChange(of: tracker.fixCount)`
/// / `.onChange(of: tracker.elapsedSeconds)` modifiers, which stop running the instant the view is
/// dismissed. Since minimizing dismisses the cover, that would otherwise freeze the Lock Screen Live
/// Activity and the Watch's live screen the moment you minimize — defeating the point of both. Driving
/// these pushes from `ContentView` (always alive while the app is foregrounded, minimized or not)
/// keeps them live regardless of presentation state. `LiveTrackingView` still owns the one-time
/// start/save/discard lifecycle and the map's guide-route fetch (which has nothing to draw while
/// minimized, so it's fine for it to pause and resume on restore).
@Observable
@MainActor
final class ActiveDriveController {
    enum Presentation: Equatable { case none, full, minimized }

    /// Everything needed to reconstruct `LiveTrackingView` identically whether this is the first
    /// presentation of a drive or a restore from minimized.
    struct Context {
        var scheduled: ScheduledDrive?
        var goTo: QuickTrip?
        var asModal: Bool
    }

    private(set) var tracker: LocationTracker?
    private(set) var context = Context(scheduled: nil, goTo: nil, asModal: false)
    var presentation: Presentation = .none

    var isFull: Bool { presentation == .full }
    var isMinimized: Bool { presentation == .minimized }
    var hasActiveDrive: Bool { tracker != nil }

    /// Begin a new drive. If one is already active, this just brings it back to full-screen instead
    /// of starting a second one — guards against a stray extra "Start a Drive" tap while a drive is
    /// minimized spinning up a second `CLLocationManager` and a second writer to the crash-safe log.
    @discardableResult
    func start(scheduled: ScheduledDrive? = nil, goTo: QuickTrip? = nil, asModal: Bool = false) -> LocationTracker {
        if let tracker {
            presentation = .full
            return tracker
        }
        let t = LocationTracker()
        tracker = t
        context = Context(scheduled: scheduled, goTo: goTo, asModal: asModal)
        presentation = .full
        return t
    }

    /// Present a recovered (crash/force-quit) session full-screen, exactly like a fresh ad-hoc drive.
    /// `LiveTrackingView`'s own recovery banner/resume flow does the actual rebuild via
    /// `tracker.resume(from:)`; this just gives it somewhere to live.
    func adoptRecovering() {
        guard tracker == nil else { return }
        tracker = LocationTracker()
        context = Context(scheduled: nil, goTo: nil, asModal: true)
        presentation = .full
    }

    /// Minimize: dismiss the full-screen cover but keep the tracker (and everything below) running.
    /// Deliberately does nothing else — no `dismiss()`, no `endLiveBroadcast()`, no
    /// `LiveActivityController.end()`. Those only happen once the drive is actually finished, via
    /// `clear()`.
    func minimize() {
        guard tracker != nil else { return }
        presentation = .minimized
    }

    func restore() {
        guard tracker != nil else { return }
        presentation = .full
    }

    /// The drive is over (saved or discarded) — drop the tracker and reset presentation entirely.
    /// Unconditionally ends the Live Activity and the Watch live broadcast: this used to be left to
    /// callers to do explicitly (only `finishAndExit()` in `LiveTrackingView` did), but `clear()` is
    /// also the `fullScreenCover` binding's setter, reachable from any system-driven dismissal — any
    /// path that reaches `clear()` without those two calls orphaned a frozen activity/broadcast for
    /// the rest of the process (or, for the Live Activity, until it auto-expired hours later). Both
    /// are safe no-ops when nothing's running.
    func clear() {
        endLiveActivity()
        endLiveBroadcast()
        tracker = nil
        context = Context(scheduled: nil, goTo: nil, asModal: false)
        presentation = .none
    }

    // MARK: - Live Activity + Watch live-broadcast (kept alive across minimize)

    #if canImport(ActivityKit) && !os(macOS)
    private func liveActivityState() -> DriveActivityAttributes.ContentState? {
        guard let tracker else { return nil }
        var progress: Double?
        if let remaining = tracker.remainingMiles {
            let done = tracker.distanceMiles
            let total = done + max(remaining, 0)
            progress = total > 0.1 ? min(1, done / total) : nil
        }
        // Show the overall destination; for a multi-leg drive, append the current leg so the Lock
        // Screen reflects the leg you're on (e.g. "Home · Stop 2 of 3").
        var name = tracker.finalDestinationName ?? tracker.destinationName
        if tracker.isMultiLeg, let base = name {
            name = "\(base) · Stop \(min(tracker.currentLegIndex + 1, tracker.totalLegs))/\(tracker.totalLegs)"
        }
        return .init(milesTraveled: tracker.distanceMiles, currentSpeed: tracker.currentSpeed,
                     elapsedSeconds: tracker.elapsedSeconds, progress: progress, eta: tracker.etaDate,
                     delaySeconds: tracker.delaySeconds, destinationName: name,
                     isPaused: tracker.isPausedBetweenLegs,
                     tripTitle: tracker.tripName ?? tracker.finalDestinationName ?? "Drive",
                     scheduledArrival: tracker.scheduledArrival)
    }
    #endif

    func startLiveActivity() {
        #if canImport(ActivityKit) && !os(macOS)
        guard let tracker, let state = liveActivityState() else { return }
        LiveActivityController.start(title: tracker.tripName ?? "Drive",
                                     scheduledArrival: tracker.scheduledArrival, state: state)
        #endif
    }

    /// Push the latest numbers to the Live Activity and the Watch. Call this on every location fix /
    /// elapsed-second tick from `ContentView` — not from `LiveTrackingView`, which may not exist right
    /// now (minimized).
    func pushLiveUpdate() {
        #if canImport(ActivityKit) && !os(macOS)
        if let tracker, tracker.isTracking, let state = liveActivityState() {
            LiveActivityController.update(state)
        }
        #endif
        broadcastLive()
    }

    /// Stream the current drive to the Apple Watch so it can be the live focus.
    func broadcastLive() {
        #if canImport(WatchConnectivity) && os(iOS)
        guard let tracker, tracker.isTracking else { return }
        var progress: Double?
        if let remaining = tracker.remainingMiles {
            let done = tracker.distanceMiles
            let total = done + max(remaining, 0)
            progress = total > 0.1 ? min(1, done / total) : nil
        }
        var legText: String?
        if tracker.isMultiLeg {
            var t = "Leg \(min(tracker.currentLegIndex + 1, tracker.totalLegs)) of \(tracker.totalLegs)"
            if let next = tracker.currentLegTarget, !next.address.isEmpty { t += " · \(next.address)" }
            legText = t
        }
        let live = WatchSyncPayload.Live(
            tripName: tracker.tripName ?? tracker.finalDestinationName ?? "Drive",
            milesTraveled: tracker.distanceMiles, currentSpeed: tracker.currentSpeed,
            elapsedSeconds: tracker.elapsedSeconds, eta: tracker.etaDate, delaySeconds: tracker.delaySeconds,
            progress: progress, legText: legText, isPaused: tracker.isPausedBetweenLegs,
            canAdvanceLeg: tracker.isMultiLeg && !tracker.isOnFinalLeg && !tracker.isPausedBetweenLegs)
        PhoneWatchConnectivity.shared.sendLive(live)
        #endif
    }

    func endLiveBroadcast() {
        #if canImport(WatchConnectivity) && os(iOS)
        PhoneWatchConnectivity.shared.sendLive(nil)
        #endif
    }

    func endLiveActivity() {
        #if canImport(ActivityKit) && !os(macOS)
        LiveActivityController.end()
        #endif
    }

    /// Push a terminal "arrived" frame (final distance/time, no more "on the way") and let the
    /// widget hold it on screen for a couple of minutes before dismissing, instead of the Live
    /// Activity just vanishing the instant the drive stops — call this right when tracking ends,
    /// before `clear()` drops the tracker this needs to build that final state from.
    func endLiveActivityWithFinalState() {
        #if canImport(ActivityKit) && !os(macOS)
        guard let state = liveActivityState() else { endLiveActivity(); return }
        LiveActivityController.endWithFinal(state)
        #endif
    }

    // MARK: - Watch remote-control (must keep working whether the drive is full-screen or minimized)

    /// The watch asked to end the in-progress drive. Stops the tracker and brings the full view back
    /// (rather than trying to show the Save/Discard summary from here) — ending a drive always needs
    /// that summary's context (vehicle, category, notes), which only the full `LiveTrackingView` has.
    /// `LiveTrackingView.setup()` detects "tracking just stopped, summary not shown yet" on appear and
    /// presents it immediately.
    func handleEndFromWatch() {
        guard let tracker, tracker.isTracking else { return }
        tracker.stopTracking()
        endLiveActivityWithFinalState()
        endLiveBroadcast()
        presentation = .full
    }

    func handleArriveFromWatch() {
        guard let tracker, tracker.isTracking, tracker.isMultiLeg,
              !tracker.isOnFinalLeg, !tracker.isPausedBetweenLegs else { return }
        tracker.arriveAtCurrentStop()
        pushLiveUpdate()
    }

    func handleStartNextLegFromWatch() {
        guard let tracker, tracker.isTracking, tracker.isPausedBetweenLegs else { return }
        tracker.startNextLeg()
        pushLiveUpdate()
    }
}
