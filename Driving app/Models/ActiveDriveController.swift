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
    /// The app's live controller, for App Intents that answer in place (e.g. "What's my ETA").
    /// `ContentView` sets this on launch.
    @ObservationIgnored static weak var current: ActiveDriveController?
    enum Presentation: Equatable { case none, full, minimized }

    /// Everything needed to reconstruct `LiveTrackingView` identically whether this is the first
    /// presentation of a drive or a restore from minimized.
    struct Context {
        var scheduled: ScheduledDrive?
        var goTo: QuickTrip?
        var asModal: Bool
        /// The saved trip this drive continues (see `resume(fromTrip:)`): replaced by the longer
        /// recording when the drive is saved, untouched if it's discarded.
        var resumedTrip: DriveTrip? = nil
    }

    /// A "drive to this saved place" request from a Shortcut / Siri, picked up by the Drive tab (which
    /// owns the go-to flow — ETA fetch, vehicle, payer) and cleared once handled.
    var pendingGoToPlaceID: UUID?

    /// Guide route + next turn (see `GuideRoute`).
    let guide = GuideRoute()

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
        wireLiveUpdates(t)
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
        let t = LocationTracker()
        wireLiveUpdates(t)
        tracker = t
        context = Context(scheduled: nil, goTo: nil, asModal: true)
        presentation = .full
    }

    /// Pick a saved trip back up — the undo for an accidental "End Drive": the tracker is rebuilt
    /// from the trip's recorded track exactly like a crash recovery, keeps recording from here, and
    /// when the drive is saved the longer recording replaces the original trip (`LiveTrackingView`
    /// handles that via `Context.resumedTrip`). Returns false when a drive is already active or the
    /// trip has no usable track.
    @discardableResult
    func resume(fromTrip trip: DriveTrip, ratedMpg: Double?) -> Bool {
        guard tracker == nil else { return false }
        let pts = trip.orderedPoints.map {
            RecordedPoint(t: $0.t, coordinate: $0.coordinate, speed: $0.speed,
                          course: $0.course, accuracy: $0.accuracy, altitude: $0.altitude)
        }
        guard pts.count >= 2 else { return false }
        // An open (destination-less) continuation: the trip's old endpoint isn't where the driver is
        // going now. A stop can be added from the live screen as usual.
        let meta = DriveLogger.Meta(
            start: trip.date, destinationName: nil, scheduledArrival: trip.scheduledArrival,
            scheduledDeparture: trip.scheduledDeparture, category: trip.categoryRaw,
            vehicleName: trip.vehicleName, tripName: trip.name, paidBy: trip.paidByRaw)
        let t = LocationTracker()
        t.ratedMpg = ratedMpg
        wireLiveUpdates(t)
        t.resume(from: DriveLogger.Recovered(meta: meta, points: pts), rewriteLog: true)
        tracker = t
        context = Context(scheduled: nil, goTo: nil, asModal: true, resumedTrip: trip)
        presentation = .full
        guide.clear(); guide.invalidate(); guide.refresh(tracker: t)
        startLiveActivity()
        broadcastLive()
        return true
    }

    /// Push the Live Activity/Watch broadcast from the model itself, not just from `ContentView`'s
    /// `.onChange(of: tracker.fixCount / elapsedSeconds)` — see `LocationTracker.onUpdate`'s doc
    /// comment for why those view-graph modifiers alone weren't enough to keep a backgrounded Live
    /// Activity live. Kept here (rather than inline at each `LocationTracker()` call site) since both
    /// need it and `pushLiveUpdate()` is already throttled, so this stays cheap.
    private func wireLiveUpdates(_ t: LocationTracker) {
        t.onUpdate = { [weak self] in self?.pushLiveUpdate() }
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
        guide.clear()
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
        let hasNextStop = tracker.isMultiLeg && !tracker.isOnFinalLeg && !tracker.isPausedBetweenLegs
        return .init(milesTraveled: tracker.distanceMiles, currentSpeed: tracker.currentSpeed,
                     elapsedSeconds: tracker.elapsedSeconds, progress: progress,
                     eta: tracker.isPausedBetweenLegs ? nil : tracker.etaDate,
                     delaySeconds: tracker.isPausedBetweenLegs ? nil : tracker.delaySeconds,
                     destinationName: name,
                     isPaused: tracker.isPausedBetweenLegs,
                     tripTitle: tracker.tripName ?? tracker.finalDestinationName ?? "Drive",
                     scheduledArrival: tracker.scheduledArrival,
                     remainingMiles: tracker.remainingMiles,
                     legRemainingMiles: hasNextStop ? tracker.legRemainingMiles : nil,
                     legEta: hasNextStop ? tracker.legEtaDate : nil,
                     legDestinationName: hasNextStop ? tracker.currentLegTarget?.address : nil,
                     isMultiLeg: tracker.isMultiLeg,
                     nextTurn: tracker.isPausedBetweenLegs ? nil : guide.nextTurn,
                     nextTurnMeters: tracker.isPausedBetweenLegs ? nil : guide.nextTurnMeters,
                     maxSpeed: tracker.maxSpeed, avgSpeed: tracker.avgSpeedMph,
                     gallonsUsed: tracker.accumulatedGallons,
                     // Only while under way: the terminal "Arrived" frame must show a frozen total,
                     // not a timer that keeps counting after the drive ended.
                     startDate: tracker.isTracking ? tracker.startTime : nil)
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
        if let tracker {
            guide.refresh(tracker: tracker)
            guide.updateNextTurn(from: tracker.currentLocation)
        }
        #if canImport(ActivityKit) && !os(macOS)
        if let tracker, tracker.isTracking, let state = liveActivityState() {
            LiveActivityController.update(state)
        }
        #endif
        broadcastLive()
    }

    private var lastWatchFrame: Date = .distantPast
    private var lastWatchFrameKey = ""

    /// Stream the current drive to the Apple Watch so it can be the live focus.
    ///
    /// Throttled to one frame a second (plus immediately on a change the driver would notice): this
    /// is called from the 1 s timer, from every location fix AND from `ContentView`'s `.onChange`
    /// drivers, so it used to send 2–4 WCSession messages per second for the whole drive.
    func broadcastLive() {
        #if canImport(WatchConnectivity) && os(iOS)
        guard let tracker, tracker.isTracking else { return }
        let key = "\(tracker.isPausedBetweenLegs)|\(tracker.currentLegIndex)|\(guide.nextTurn ?? "")|\(Int(tracker.distanceMiles * 10))"
        let now = Date()
        if now.timeIntervalSince(lastWatchFrame) < 1, key == lastWatchFrameKey { return }
        lastWatchFrame = now
        lastWatchFrameKey = key
        var progress: Double?
        if let remaining = tracker.remainingMiles {
            let done = tracker.distanceMiles
            let total = done + max(remaining, 0)
            progress = total > 0.1 ? min(1, done / total) : nil
        }
        var legText: String?
        if tracker.isMultiLeg {
            let targetIndex = tracker.currentLegIndex + (tracker.isPausedBetweenLegs ? 1 : 0)
            let target = tracker.legTargets.indices.contains(targetIndex) ? tracker.legTargets[targetIndex] : nil
            let legNumber = min(targetIndex + 1, tracker.totalLegs)
            var text = tracker.isPausedBetweenLegs
                ? "Next · \(legNumber) of \(tracker.totalLegs)"
                : "Leg \(legNumber) of \(tracker.totalLegs)"
            if let address = target?.address, !address.isEmpty { text += " · \(address)" }
            legText = text
        }
        let hasNextStop = tracker.isMultiLeg && !tracker.isOnFinalLeg && !tracker.isPausedBetweenLegs
        let live = WatchSyncPayload.Live(
            tripName: tracker.tripName ?? tracker.finalDestinationName ?? "Drive",
            milesTraveled: tracker.distanceMiles, currentSpeed: tracker.currentSpeed,
            elapsedSeconds: tracker.elapsedSeconds,
            eta: tracker.isPausedBetweenLegs ? nil : tracker.etaDate,
            delaySeconds: tracker.isPausedBetweenLegs ? nil : tracker.delaySeconds,
            progress: progress, legText: legText, isPaused: tracker.isPausedBetweenLegs,
            canAdvanceLeg: tracker.isMultiLeg && !tracker.isOnFinalLeg && !tracker.isPausedBetweenLegs,
            remainingMiles: tracker.remainingMiles,
            legRemainingMiles: hasNextStop ? tracker.legRemainingMiles : nil,
            legEta: hasNextStop ? tracker.legEtaDate : nil,
            nextTurn: tracker.isPausedBetweenLegs ? nil : guide.nextTurn,
            nextTurnMeters: tracker.isPausedBetweenLegs ? nil : guide.nextTurnMeters,
            destinationName: tracker.finalDestinationName ?? tracker.destinationName,
            maxSpeed: tracker.maxSpeed,
            isStopped: tracker.currentSpeed < 3,
            sentAt: now)
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
