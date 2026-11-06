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
    /// Reads the same on-disk store the app uses (a read-only fetch; the app owns all writes).
    @MainActor
    private func allPlaces() -> [PlaceEntity] {
        guard let container = try? ModelContainer(for: DriveTrip.self, TrackPoint.self, ScheduledDrive.self,
                                                  GasEntry.self, Vehicle.self, UserSettings.self,
                                                  SavedPlace.self, PayerGroup.self),
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

    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.shared.post(.endDrive)
        return .result()
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
    }
}
