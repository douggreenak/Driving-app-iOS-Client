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

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Ask the phone to start a scheduled drive by its id.
    func startDrive(id: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let message = ["action": "start", "id": id]
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            // Not reachable right now — queue it so the phone gets it when it wakes.
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

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Pick up whatever context was last delivered while we were asleep.
        let ctx = session.receivedApplicationContext
        Task { @MainActor in self.decode(ctx) }
    }
}
