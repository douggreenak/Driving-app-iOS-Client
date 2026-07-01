import SwiftUI
import SwiftData
import MapKit

@main
struct DriveTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [DriveTrip.self, TrackPoint.self, ScheduledDrive.self,
                              GasEntry.self, Vehicle.self, UserSettings.self, SavedPlace.self])
    }
}

/// Routes to either the normal app or, under DEBUG when `UITEST_SCREEN` is set, a single
/// seeded screen for headless screenshots.
struct RootView: View {
    var body: some View {
        #if DEBUG
        if let screen = ProcessInfo.processInfo.environment["UITEST_SCREEN"] {
            ScreenshotHarness(screen: screen)
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}

/// Warms the MapKit engine once, shortly after launch, so the first `Map` (on the Track tab)
/// doesn't pay the engine's one-time init cost as a visible hitch.
@MainActor
enum MapPrewarmer {
    private static var holder: MKMapView?
    static func warm() {
        guard holder == nil else { return }
        holder = MKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        Task { try? await Task.sleep(for: .seconds(5)); holder = nil }
    }
}

/// The app's top-level tabs. Backing the TabView with an explicit selection lets a finished drive
/// route the user straight back to the Dashboard.
enum AppTab: Hashable { case dashboard, track, schedule, trips, gas }

struct ContentView: View {
    @State private var selection: AppTab = .dashboard
    @Query private var scheduled: [ScheduledDrive]
    /// A scheduled drive the watch asked us to start, presented as live tracking.
    @State private var watchStart: WatchStartRequest?

    var body: some View {
        TabView(selection: $selection) {
            Tab("Dashboard", systemImage: "square.grid.2x2.fill", value: AppTab.dashboard) {
                DashboardView()
            }
            Tab("Track", systemImage: "location.fill", value: AppTab.track) {
                LiveTrackingView(onFinish: { selection = .dashboard })
            }
            Tab("Schedule", systemImage: "calendar", value: AppTab.schedule) {
                ScheduleView()
            }
            Tab("Trips", systemImage: "map.fill", value: AppTab.trips) {
                TripsListView()
            }
            Tab("Gas", systemImage: "fuelpump.fill", value: AppTab.gas) {
                GasListView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            #if canImport(WatchConnectivity) && os(iOS)
            PhoneWatchConnectivity.shared.activate()
            #endif
            // Let the dashboard settle, then warm MapKit in the background.
            try? await Task.sleep(for: .milliseconds(600))
            MapPrewarmer.warm()
        }
        #if canImport(WatchConnectivity) && os(iOS)
        .fullScreenCover(item: $watchStart) { req in
            if let drive = scheduled.first(where: { $0.id.uuidString == req.id }) {
                LiveTrackingView(scheduled: drive)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startDriveFromWatch)) { note in
            // The watch tapped "Start" on a scheduled drive — open live tracking for it.
            guard let id = note.userInfo?["id"] as? String else { return }
            selection = .track
            watchStart = WatchStartRequest(id: id)
        }
        #endif
    }
}

/// Identifiable wrapper so a watch "start" request can drive a `.fullScreenCover(item:)`.
struct WatchStartRequest: Identifiable { let id: String }
