import Foundation
import Observation
import SwiftUI
import WatchConnectivity

/// Resolves a payer group's `colorName` (sent from the phone — see `PayerGroup.colorPresets` in the
/// app target) to a `Color`. The watch has no `PayerGroup` model of its own, so this small mirrored
/// lookup table is the only place that name set needs to stay in sync between targets.
enum WatchPayerColor {
    private static let presets: [String: Color] = [
        "blue": .blue, "green": .green, "orange": .orange, "purple": .purple,
        "pink": .pink, "teal": .teal, "red": .red, "yellow": .yellow, "indigo": .indigo,
    ]
    static func color(for name: String) -> Color { presets[name] ?? .blue }
}

/// Mirror of the phone's `WatchSyncPayload`. Keep the field names identical on both sides.
struct WatchSyncPayload: Codable {
    /// A payer group's resolved display attributes + cost, as sent from the phone — the watch has no
    /// `PayerGroup` store of its own, so it always renders from these already-resolved strings.
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
        var payerStats: [PayerStat]
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
                      endName: "Apex Engineering", payerKey: "PARENTS", payerName: "Parents",
                      payerIconName: "person.2.fill", payerColorName: "green"),
                .init(id: "2", title: "Gym", departure: Date().addingTimeInterval(3 * 3600),
                      endName: "The Alaska Club", payerKey: "SELF", payerName: "Me",
                      payerIconName: "person.fill", payerColorName: "blue"),
                .init(id: "3", title: "School Pickup", departure: Date().addingTimeInterval(5 * 3600),
                      endName: "Home", payerKey: "PARENTS", payerName: "Parents",
                      payerIconName: "person.2.fill", payerColorName: "green"),
            ],
            stats: .init(totalMiles: 1240, totalDrives: 68, totalGallons: 47.5,
                         totalSeconds: 41 * 3600, topSpeed: 72,
                         payerStats: [
                            .init(key: "SELF", name: "Me", iconName: "person.fill", colorName: "blue", cost: 38.20),
                            .init(key: "PARENTS", name: "Parents", iconName: "person.2.fill", colorName: "green", cost: 121.55),
                         ],
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
