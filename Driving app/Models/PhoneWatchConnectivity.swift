import Foundation

// Notification names are always available so the live-tracking view can observe them on any
// platform; the WatchConnectivity machinery below is iOS-only.
extension Notification.Name {
    /// Posted when the watch asks the phone to start a scheduled drive; `userInfo["id"]` is its UUID.
    static let startDriveFromWatch = Notification.Name("startDriveFromWatch")
    /// The watch asked to end the in-progress drive.
    static let endDriveFromWatch = Notification.Name("endDriveFromWatch")
    /// The watch marked the current stop reached (advance to the next leg).
    static let arriveStopFromWatch = Notification.Name("arriveStopFromWatch")
    /// The watch asked to resume the next leg after a stop.
    static let startNextLegFromWatch = Notification.Name("startNextLegFromWatch")
}

#if canImport(WatchConnectivity) && os(iOS)
import WatchConnectivity

/// The data the phone mirrors to the watch: the upcoming drives (so the watch can start one) and a
/// few headline stats. Kept small and Codable — sent as WatchConnectivity application context
/// (latest-state-wins). The watch decodes an identical struct.
struct WatchSyncPayload: Codable {
    /// A payer group's resolved display attributes + cost, as sent to the watch — a thin display
    /// client with no `PayerGroup` store of its own, so it always works from these already-resolved
    /// strings rather than looking anything up itself.
    struct PayerStat: Codable, Identifiable {
        var key: String
        var name: String
        var iconName: String
        var colorName: String
        var cost: Double
        var id: String { key }
    }
    struct Drive: Codable, Identifiable {
        var id: String
        var title: String
        var departure: Date
        var endName: String
        var payerKey: String
        var payerName: String
        var payerIconName: String
        var payerColorName: String
    }
    struct Stats: Codable {
        var totalMiles: Double
        var totalDrives: Int
        var totalGallons: Double
        var totalSeconds: Int
        var topSpeed: Double
        /// Estimated gas cost split (this pay period) — the app's core "who pays" concept. An ordered
        /// array (not a dictionary) so the watch renders bars in a stable, sort-respecting sequence.
        var payerStats: [PayerStat]
        /// On-time performance across scheduled-and-completed drives.
        var onTimePercent: Double
        var scheduledCount: Int
    }
    /// The drive currently being recorded, streamed to the watch so it can be the live focus.
    struct Live: Codable {
        var tripName: String
        var milesTraveled: Double
        var currentSpeed: Double
        var elapsedSeconds: Int
        var eta: Date?
        var delaySeconds: Int?
        var progress: Double?
        var legText: String?
        var isPaused: Bool
        /// True when an intermediate stop can be marked reached (multi-leg, mid-route, moving).
        var canAdvanceLeg: Bool
    }
    var drives: [Drive]
    var stats: Stats
}

/// Phone half of the watch link: pushes drives + stats to the watch and forwards the watch's
/// "start this drive" requests into the app as a notification. Safe to activate with no watch
/// paired — the session simply has no counterpart.
@MainActor
final class PhoneWatchConnectivity: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchConnectivity()

    /// The last payload handed to `sync(_:)`, re-sent once activation actually completes — see its
    /// call site's doc comment.
    private var pendingSync: WatchSyncPayload?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Mirror the latest drives + stats to the watch (latest-state-wins application context).
    func sync(_ payload: WatchSyncPayload) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        // `activate()` is asynchronous — `ContentView`'s own launch `.task`s call `activate()` and
        // this `sync()` in a race, so the very first (and, since `broadcastToWatch()`'s `watchSyncKey`
        // only changes when the drive/trip COUNT changes, sometimes the only) sync of a launch used to
        // just silently drop here because activation hadn't completed yet. Stash it regardless of
        // activation state so `activationDidCompleteWith` below can flush it once activation lands.
        pendingSync = payload
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(payload) else { return }
        try? session.updateApplicationContext(["payload": data])
        pendingSync = nil
    }

    /// Stream the current live drive to the watch (or clear it when the drive ends). The live frames
    /// themselves are sent as a message — separate from the application context so it doesn't wipe
    /// the drives/stats — and only while the watch app is reachable (ephemeral; no point queuing a
    /// frame that will be stale by the time it's delivered). The END terminator is different: it's
    /// the only thing that ever clears `WatchConnectivityManager.live`, so losing it — the watch
    /// unreachable at the exact moment a drive ends, extremely common (wrist down, watch app
    /// backgrounded) — left the watch showing a frozen "live" drive with dead End/Arrived controls
    /// until the watch app was force-quit. Always queue it via `transferUserInfo` too, so a delayed
    /// delivery still eventually clears it.
    func sendLive(_ live: WatchSyncPayload.Live?) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if let live, let data = try? JSONEncoder().encode(live) {
            guard session.isReachable else { return }
            session.sendMessage(["live": data], replyHandler: nil, errorHandler: nil)
        } else {
            let payload: [String: Any] = ["liveEnded": true]
            if session.isReachable { session.sendMessage(payload, replyHandler: nil, errorHandler: nil) }
            try? session.transferUserInfo(payload)
        }
    }

    // MARK: WCSessionDelegate (delegate callbacks arrive off the main actor)

    /// Shared handling for a watch action, whether it arrived as an immediate message (watch app was
    /// reachable) or a queued user-info transfer (it wasn't — see `didReceiveUserInfo` below).
    private func handleAction(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        switch action {
        case "start":
            if let id = message["id"] as? String {
                NotificationCenter.default.post(name: .startDriveFromWatch, object: nil, userInfo: ["id": id])
            }
        case "end":     NotificationCenter.default.post(name: .endDriveFromWatch, object: nil)
        case "arrive":  NotificationCenter.default.post(name: .arriveStopFromWatch, object: nil)
        case "nextLeg": NotificationCenter.default.post(name: .startNextLegFromWatch, object: nil)
        default: break
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handleAction(message) }
    }

    /// `WatchConnectivityManager.send(_:queueIfNeeded:)` falls back to `transferUserInfo` whenever
    /// the phone isn't reachable — the normal case for "start my commute from my wrist while the
    /// phone is in my pocket" — and this delegate callback is how that queued transfer actually
    /// arrives. Without it, every watch action sent while the phone app wasn't foregrounded (or the
    /// `sendLive` terminator above) was delivered by the system and then silently dropped here.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.handleAction(userInfo) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // The watch side already re-reads `receivedApplicationContext` here on its own activation
        // completion; the phone side never retried its outgoing sync at all, so a schedule/trip edit
        // that changed nothing about the drive/trip *count* (`broadcastToWatch`'s `watchSyncKey`) —
        // e.g. only a departure time or destination changed — could go out while this session hadn't
        // finished activating yet (see `sync(_:)`) and never get resent.
        Task { @MainActor in if let payload = self.pendingSync { self.sync(payload) } }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
#endif
