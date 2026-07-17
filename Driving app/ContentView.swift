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

/// Warms the MapKit engine once, shortly after launch, so the first `Map` (in live tracking)
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

/// The app's top-level tabs. Backing the TabView with an explicit selection lets a watch-started
/// drive route the user back to the Drive home.
enum AppTab: Hashable { case drive, stats, trips, gas }

struct ContentView: View {
    @State private var selection: AppTab = .drive
    @Query private var scheduled: [ScheduledDrive]
    @Query(sort: \DriveTrip.date, order: .reverse) private var allTrips: [DriveTrip]
    @Query private var vehicles: [Vehicle]
    @Query private var settingsList: [UserSettings]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    /// A scheduled drive the watch asked us to start, presented as live tracking.
    @State private var watchStart: WatchStartRequest?

    private var fuelPrice: Double { settingsList.first?.fuelPricePerGallon ?? 3.75 }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Drive", systemImage: "location.fill", value: AppTab.drive) {
                DriveHomeView()
            }
            Tab("Stats", systemImage: "chart.bar.fill", value: AppTab.stats) {
                StatsView()
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
            // Let the home settle, then warm MapKit in the background.
            try? await Task.sleep(for: .milliseconds(600))
            MapPrewarmer.warm()
        }
        .task {
            // Push local trips up (incl. any unsynced) and backfill payer onto historical trips so
            // all current app data reaches the server. Centralized here so it runs regardless of tab.
            await TripStore.syncPending(context: modelContext)
            await TripStore.backfillPaidBy(context: modelContext)
        }
        .task(id: watchSyncKey) { broadcastToWatch() }
        #if canImport(WatchConnectivity) && os(iOS)
        .fullScreenCover(item: $watchStart) { req in
            if let drive = scheduled.first(where: { $0.id.uuidString == req.id }) {
                LiveTrackingView(scheduled: drive, onFinish: { watchStart = nil; selection = .drive })
            } else {
                // The requested drive no longer exists (deleted/canceled on the phone before the
                // watch re-synced). Show a dismissable message instead of a stuck black cover.
                watchStartMissing
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startDriveFromWatch)) { note in
            // The watch tapped "Start" on a scheduled drive — open live tracking for it, but only
            // if it still exists locally (a stale cached row must not present a blank cover).
            guard let id = note.userInfo?["id"] as? String,
                  scheduled.contains(where: { $0.id.uuidString == id }) else { return }
            selection = .drive
            watchStart = WatchStartRequest(id: id)
        }
        #endif
    }

    @Environment(\.modelContext) private var modelContext

    /// Changes whenever the drives/trips the watch mirrors change, so we re-push then.
    private var watchSyncKey: String { "\(scheduled.count)-\(allTrips.count)" }

    /// Mirror upcoming drives + headline stats to the Apple Watch companion.
    private func broadcastToWatch() {
        #if canImport(WatchConnectivity) && os(iOS)
        let now = Date.now
        let fillUps = Dictionary(vehicles.compactMap { v in v.lastFilledUp.map { (v.name, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        let stats = DrivingStats(trips: allTrips, fillUps: fillUps)
        let drives = scheduled
            .filter { $0.isEnabled }
            .compactMap { d -> (WatchSyncPayload.Drive, Date)? in
                guard let dep = d.upNextDeparture(now: now) else { return nil }
                return (WatchSyncPayload.Drive(
                    id: d.id.uuidString, title: d.title, departure: dep,
                    endName: PlaceNamer.name(for: d.endCoordinate, fallback: d.endAddress, in: savedPlaces),
                    paidByParents: d.paidBy == .parents), dep)
            }
            .sorted { abs($0.1.timeIntervalSince(now)) < abs($1.1.timeIntervalSince(now)) }
            .prefix(10)
            .map(\.0)
        let price = fuelPrice
        let payload = WatchSyncPayload(
            drives: Array(drives),
            stats: .init(totalMiles: stats.totalMiles, totalDrives: stats.driveCount,
                         totalGallons: stats.totalGallons, totalSeconds: stats.totalSeconds,
                         topSpeed: stats.topSpeed,
                         meCost: stats.cost(for: .myself, pricePerGallon: price),
                         parentsCost: stats.cost(for: .parents, pricePerGallon: price),
                         onTimePercent: stats.onTimePercent, scheduledCount: stats.scheduledCount))
        PhoneWatchConnectivity.shared.sync(payload)
        #endif
    }

    #if canImport(WatchConnectivity) && os(iOS)
    private var watchStartMissing: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text("Drive not found").font(.headline)
            Text("This scheduled drive is no longer available on your phone.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close") { watchStart = nil }.buttonStyle(.borderedProminent)
        }
        .padding()
    }
    #endif
}

/// Identifiable wrapper so a watch "start" request can drive a `.fullScreenCover(item:)`.
struct WatchStartRequest: Identifiable { let id: String }
