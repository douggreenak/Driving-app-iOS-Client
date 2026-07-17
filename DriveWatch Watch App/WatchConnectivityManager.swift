import Foundation
import Observation
import WatchConnectivity

/// Mirror of the phone's `WatchSyncPayload`. Keep the field names identical on both sides.
struct WatchSyncPayload: Codable {
    struct Drive: Codable, Identifiable {
        var id: String
        var title: String
        var departure: Date
        var endName: String
        var paidByParents: Bool
    }
    struct Stats: Codable {
        var totalMiles: Double
        var totalDrives: Int
        var totalGallons: Double
        var totalSeconds: Int
        var topSpeed: Double
        var meCost: Double
        var parentsCost: Double
        var onTimePercent: Double
        var scheduledCount: Int
    }
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
        var canAdvanceLeg: Bool
    }
    var drives: [Drive]
    var stats: Stats
}

/// Watch half of the link: receives the mirrored drives + stats from the phone and sends "start
/// this drive" requests back.
@MainActor
@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    var payload: WatchSyncPayload?
    /// The drive currently being recorded on the phone, streamed live. Nil when nothing is active.
    var live: WatchSyncPayload.Live?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Ask the phone to start a scheduled drive by its id.
    func startDrive(id: String) { send(["action": "start", "id": id], queueIfNeeded: true) }
    /// Live-drive controls (only meaningful while a drive is active, so no need to queue).
    func endDrive()     { send(["action": "end"]) }
    func arriveAtStop() { send(["action": "arrive"]) }
    func startNextLeg() { send(["action": "nextLeg"]) }

    private func send(_ message: [String: Any], queueIfNeeded: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else if queueIfNeeded {
            try? session.transferUserInfo(message)
        }
    }

    private func decode(_ context: [String: Any]) {
        guard let data = context["payload"] as? Data,
              let decoded = try? JSONDecoder().decode(WatchSyncPayload.self, from: data) else { return }
        payload = decoded
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.decode(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if let data = message["live"] as? Data,
               let decoded = try? JSONDecoder().decode(WatchSyncPayload.Live.self, from: data) {
                self.live = decoded
            } else if message["liveEnded"] != nil {
                self.live = nil
            }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Pick up whatever context was last delivered while we were asleep.
        let ctx = session.receivedApplicationContext
        Task { @MainActor in self.decode(ctx) }
    }
}

#if DEBUG
extension WatchSyncPayload {
    /// Seeded data for headless screenshots of the watch app (see `WATCH_PREVIEW`).
    static var sample: WatchSyncPayload {
        WatchSyncPayload(
            drives: [
                .init(id: "1", title: "Morning Commute", departure: Date().addingTimeInterval(25 * 60),
                      endName: "Apex Engineering", paidByParents: true),
                .init(id: "2", title: "Gym", departure: Date().addingTimeInterval(3 * 3600),
                      endName: "The Alaska Club", paidByParents: false),
                .init(id: "3", title: "School Pickup", departure: Date().addingTimeInterval(5 * 3600),
                      endName: "Home", paidByParents: true),
            ],
            stats: .init(totalMiles: 1240, totalDrives: 68, totalGallons: 47.5,
                         totalSeconds: 41 * 3600, topSpeed: 72,
                         meCost: 38.20, parentsCost: 121.55,
                         onTimePercent: 86, scheduledCount: 40))
    }

    /// A live multi-stop drive in progress, for screenshotting the live screen.
    static var sampleLive: Live {
        Live(tripName: "Morning Commute", milesTraveled: 4.2, currentSpeed: 38,
             elapsedSeconds: 12 * 60 + 34, eta: Date().addingTimeInterval(9 * 60),
             delaySeconds: 240, progress: 0.55, legText: "Leg 2 of 3 · Spenard Post Office",
             isPaused: false, canAdvanceLeg: true)
    }
}
#endif
