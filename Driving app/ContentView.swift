import SwiftUI
import SwiftData

@main
struct DriveTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Trip.self, GasEntry.self, Vehicle.self, UserSettings.self])
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
    }
}
