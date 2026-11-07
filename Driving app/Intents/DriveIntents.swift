import AppIntents
import SwiftData
import Foundation

// MARK: - Shortcuts / Siri
//
// Exposes the app's saved places as Shortcut destinations, so Apple Shortcuts (and Siri) can say
// "Drive to Home with Drive Tracker", start an open drive, or end the current one.

/// A saved place, as a Shortcuts parameter.
struct PlaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static let defaultQuery = PlaceEntityQuery()

    var id: UUID
    var label: String
    var address: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(address)")
    }
}

struct PlaceEntityQuery: EntityQuery, EntityStringQuery {
    /// One container for every Siri/Shortcuts lookup — opening a fresh one per parameter screen
    /// (three query methods, each called repeatedly while Shortcuts disambiguates) was slow and put
    /// a second container on the same store in the app process.
    @MainActor
    private static let container: ModelContainer? = try? ModelContainer(
        for: DriveTrip.self, TrackPoint.self, ScheduledDrive.self, GasEntry.self, Vehicle.self,
        UserSettings.self, SavedPlace.self, PayerGroup.self)

    /// Reads the same on-disk store the app uses (a read-only fetch; the app owns all writes).
    @MainActor
    private func allPlaces() -> [PlaceEntity] {
        guard let container = Self.container,
              let places = try? container.mainContext.fetch(
                FetchDescriptor<SavedPlace>(sortBy: [SortDescriptor(\.sortOrder)]))
        else { return [] }
        return places.map { PlaceEntity(id: $0.id, label: $0.label, address: $0.address) }
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [PlaceEntity] {
        allPlaces().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [PlaceEntity] { allPlaces() }
    @MainActor func entities(matching string: String) async throws -> [PlaceEntity] {
        allPlaces().filter { $0.label.localizedCaseInsensitiveContains(string) }
    }
}

/// Hand-off from an intent to the running app. Intents run with the app opened (`openAppWhenRun`),
/// and `ContentView` drains this on launch and on every request.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    enum Request: Equatable { case goTo(UUID), startOpenDrive, endDrive }
    private(set) var pending: [Request] = []
    var onRequest: (() -> Void)?

    func post(_ r: Request) {
        pending.append(r)
        onRequest?()
    }
    func take() -> [Request] { defer { pending = [] }; return pending }
}

struct DriveToPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Drive to a Place"
    static let description = IntentDescription("Start a tracked drive to one of your saved places, with a live ETA.")
    static let openAppWhenRun = true

    @Parameter(title: "Place") var place: PlaceEntity

    static var parameterSummary: some ParameterSummary { Summary("Drive to \(\.$place)") }

    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.shared.post(.goTo(place.id))
        return .result()
    }
}

struct StartDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Drive"
    static let description = IntentDescription("Start recording a drive with no destination.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.shared.post(.startOpenDrive)
        return .result()
    }
}

struct EndDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "End Drive"
    static let description = IntentDescription("Stop the drive that's being recorded.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ActiveDriveController.current?.tracker?.isTracking == true else {
            return .result(dialog: "No drive is being recorded right now.")
        }
        IntentBridge.shared.post(.endDrive)
        return .result(dialog: "Ending your drive.")
    }
}

/// "What's my ETA?" — answers from the live tracker without opening the app, so it works hands-free
/// through Siri/CarPlay while driving.
struct DriveStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Drive Status"
    static let description = IntentDescription("Hear the ETA, delay and distance left for the drive being recorded.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let tracker = ActiveDriveController.current?.tracker, tracker.isTracking else {
            return .result(dialog: "No drive is being recorded right now.")
        }
        var parts: [String] = []
        if tracker.isPausedBetweenLegs {
            parts.append("You're parked at a stop")
        } else if let eta = tracker.etaDate {
            let name = tracker.finalDestinationName ?? tracker.destinationName
            parts.append("Arriving" + (name.map { " at \($0)" } ?? "") + " around \(eta.formatted(date: .omitted, time: .shortened))")
            if let d = tracker.delaySeconds {
                let m = max(1, abs(d) / 60)
                if d > 90 { parts.append("\(m) minute\(m == 1 ? "" : "s") late") }
                else if d < -90 { parts.append("\(m) minute\(m == 1 ? "" : "s") early") }
                else { parts.append("on time") }
            }
        } else {
            parts.append("Recording a drive with no destination")
        }
        if let left = tracker.remainingMiles { parts.append(String(format: "%.0f miles to go", left)) }
        parts.append(String(format: "%.1f miles so far", tracker.distanceMiles))
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: ", ") + "."))
    }
}

struct DriveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DriveToPlaceIntent(),
                    phrases: ["Drive to \(\.$place) with \(.applicationName)",
                              "Navigate to \(\.$place) with \(.applicationName)",
                              "Take me to \(\.$place) with \(.applicationName)"],
                    shortTitle: "Drive to…", systemImageName: "location.fill")
        AppShortcut(intent: StartDriveIntent(),
                    phrases: ["Start a drive with \(.applicationName)", "Start tracking with \(.applicationName)"],
                    shortTitle: "Start Drive", systemImageName: "play.fill")
        AppShortcut(intent: EndDriveIntent(),
                    phrases: ["End my drive with \(.applicationName)", "Stop tracking with \(.applicationName)"],
                    shortTitle: "End Drive", systemImageName: "stop.fill")
        AppShortcut(intent: DriveStatusIntent(),
                    phrases: ["What's my ETA with \(.applicationName)", "Am I late with \(.applicationName)",
                              "Drive status with \(.applicationName)"],
                    shortTitle: "Drive Status", systemImageName: "clock.fill")
    }
}
