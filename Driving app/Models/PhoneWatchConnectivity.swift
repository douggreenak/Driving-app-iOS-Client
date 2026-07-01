import Foundation
#if canImport(WatchConnectivity) && os(iOS)
import WatchConnectivity

/// The data the phone mirrors to the watch: the upcoming drives (so the watch can start one) and a
/// few headline stats. Kept small and Codable — sent as WatchConnectivity application context
/// (latest-state-wins). The watch decodes an identical struct.
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

extension Notification.Name {
    /// Posted when the watch asks the phone to start a scheduled drive; `userInfo["id"]` is its UUID.
    static let startDriveFromWatch = Notification.Name("startDriveFromWatch")
}

/// Phone half of the watch link: pushes drives + stats to the watch and forwards the watch's
/// "start this drive" requests into the app as a notification. Safe to activate with no watch
/// paired — the session simply has no counterpart.
@MainActor
final class PhoneWatchConnectivity: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchConnectivity()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Mirror the latest drives + stats to the watch.
    func sync(_ payload: WatchSyncPayload) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(payload) else { return }
        try? session.updateApplicationContext(["payload": data])
    }

    // MARK: WCSessionDelegate (delegate callbacks arrive off the main actor)

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["action"] as? String == "start", let id = message["id"] as? String else { return }
        Task { @MainActor in
            NotificationCenter.default.post(name: .startDriveFromWatch, object: nil, userInfo: ["id": id])
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
#endif
