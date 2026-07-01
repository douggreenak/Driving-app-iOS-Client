import Foundation
#if canImport(ActivityKit) && !os(macOS)
import ActivityKit

/// Starts, updates, and ends the drive Live Activity. All calls are safe no-ops when Live
/// Activities are disabled or the widget extension isn't installed, so the app builds and runs
/// with or without the extension target present.
@MainActor
enum LiveActivityController {
    private static var activity: Activity<DriveActivityAttributes>?

    /// Begin a Live Activity for a drive. Ignored if one is already running or the user has Live
    /// Activities turned off.
    static func start(title: String, scheduledArrival: Date?, state: DriveActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let attributes = DriveActivityAttributes(tripTitle: title, scheduledArrival: scheduledArrival)
        activity = try? Activity.request(attributes: attributes,
                                         content: .init(state: state, staleDate: nil))
    }

    /// Push the latest trip numbers to the running activity.
    static func update(_ state: DriveActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// End and dismiss the activity when the drive stops.
    static func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
