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

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: "square.grid.2x2.fill") {
                DashboardView()
            }
            Tab("Track", systemImage: "location.fill") {
                LiveTrackingView()
            }
            Tab("Schedule", systemImage: "calendar") {
                ScheduleView()
            }
            Tab("Trips", systemImage: "map.fill") {
                TripsListView()
            }
            Tab("Gas", systemImage: "fuelpump.fill") {
                GasListView()
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Let the dashboard settle, then warm MapKit in the background.
            try? await Task.sleep(for: .milliseconds(600))
            MapPrewarmer.warm()
        }
    }
}
