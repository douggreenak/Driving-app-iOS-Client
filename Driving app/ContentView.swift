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
                              GasEntry.self, Vehicle.self, UserSettings.self, SavedPlace.self,
                              PayerGroup.self])
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

/// Environment token that changes whenever the user switches tabs or the app returns to the
/// foreground. Views with a network-backed load that only fires once per view identity (a bare
/// `.task { await load() }`) bind it via `.task(id: activityToken)` so they refetch on every tab
/// revisit or app resume instead of showing stale data until a full relaunch.
private struct TabActivityTokenKey: EnvironmentKey {
    static let defaultValue = 0
}
extension EnvironmentValues {
    var tabActivityToken: Int {
        get { self[TabActivityTokenKey.self] }
        set { self[TabActivityTokenKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var selection: AppTab = .drive
    @Query private var scheduled: [ScheduledDrive]
    @Query(sort: \DriveTrip.date, order: .reverse) private var allTrips: [DriveTrip]
    @Query private var vehicles: [Vehicle]
    @Query private var settingsList: [UserSettings]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]
    /// A scheduled drive the watch asked us to start, presented as live tracking.
    @State private var watchStart: WatchStartRequest?
    /// Owns the currently-tracking (or minimized) drive for the whole app lifetime — see
    /// `ActiveDriveController` for why this has to live above any single tab's view.
    @State private var activeDrive = ActiveDriveController()
    @State private var activityToken = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    private var fuelPrice: Double { settingsList.first?.fuelPricePerGallon ?? 3.75 }

    var body: some View {
        ZStack(alignment: .bottom) {
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

            if activeDrive.isMinimized, let tracker = activeDrive.tracker {
                MinimizedDriveBar(tracker: tracker) {
                    Haptics.tap()
                    activeDrive.restore()
                }
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeDrive.isMinimized)
        .environment(activeDrive)
        .environment(\.tabActivityToken, activityToken)
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
            PayerGroupStore.seedIfNeeded(context: modelContext)
            #if DEBUG
            // Manual-testing fixture — see `SampleData.seedEverythingForTesting`. Only runs when
            // explicitly launched with `UITEST_SEED=1`; never in a normal debug or release run.
            if ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" {
                SampleData.seedEverythingForTesting(context: modelContext)
            }
            #endif
            // Push local trips up (incl. any unsynced) and backfill payer onto historical trips so
            // all current app data reaches the server. Centralized here so it runs regardless of tab.
            await TripStore.syncPending(context: modelContext)
            await TripStore.backfillPaidBy(context: modelContext)
            // A genuine in-progress drive keeps its Live Activity running through this launch (its
            // recovery banner will offer to resume/save it); only sweep away an activity nothing is
            // recovering, which means the app force-quit and never got a chance to end it itself.
            #if canImport(ActivityKit) && !os(macOS)
            if LocationTracker.recoverableSession() == nil {
                await LiveActivityController.endOrphaned()
            }
            #endif
        }
        .task(id: watchSyncKey) { broadcastToWatch() }
        .onChange(of: selection) { _, _ in activityToken += 1 }
        .onChange(of: scenePhase) { old, new in
            if new == .active, old != .active { activityToken += 1 }
        }
        .fullScreenCover(isPresented: Binding(
            get: { activeDrive.isFull },
            // SwiftUI routes any system-driven dismissal (e.g. `LiveTrackingView`'s own
            // `@Environment(\.dismiss)` call when closing before a drive has started) through this
            // setter — without handling `false` here that path would desync from `activeDrive`'s own
            // state (the cover visually dismisses but `activeDrive` still thinks a drive is active).
            // Clearing mirrors what a not-yet-started drive's close button already means: there's
            // nothing to minimize, so tear the whole thing down.
            set: { if !$0 { activeDrive.clear() } }
        )) {
            if let tracker = activeDrive.tracker {
                LiveTrackingView(tracker: tracker, scheduled: activeDrive.context.scheduled,
                                 asModal: activeDrive.context.asModal, goTo: activeDrive.context.goTo,
                                 onFinish: { activeDrive.clear(); watchStart = nil; selection = .drive })
            }
        }
        #if canImport(WatchConnectivity) && os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .startDriveFromWatch)) { note in
            // The watch tapped "Start" on a scheduled drive — open live tracking for it, but only
            // if it still exists locally (a stale cached row must not present a blank cover), and
            // only if nothing is already being tracked (mirrors `ActiveDriveController.start`'s own
            // guard, but we need to check *before* calling it so we can show "drive not found"
            // instead of silently restoring whatever's already active).
            guard let id = note.userInfo?["id"] as? String else { return }
            guard let drive = scheduled.first(where: { $0.id.uuidString == id }) else {
                watchStart = WatchStartRequest(id: id)
                return
            }
            selection = .drive
            activeDrive.start(scheduled: drive)
        }
        .onReceive(NotificationCenter.default.publisher(for: .endDriveFromWatch)) { _ in
            activeDrive.handleEndFromWatch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arriveStopFromWatch)) { _ in
            activeDrive.handleArriveFromWatch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startNextLegFromWatch)) { _ in
            activeDrive.handleStartNextLegFromWatch()
        }
        // "Drive not found": the watch asked to start a drive that no longer exists locally. Shown
        // as its own small cover rather than routing through `activeDrive` (there's no tracker to
        // show/minimize for a drive that was never found).
        .fullScreenCover(item: $watchStart) { _ in watchStartMissing }
        #endif
    }

    /// Changes whenever the drives/trips the watch mirrors change, so we re-push then.
    private var watchSyncKey: String { "\(scheduled.count)-\(allTrips.count)" }

    /// Mirror upcoming drives + headline stats to the Apple Watch companion.
    private func broadcastToWatch() {
        #if canImport(WatchConnectivity) && os(iOS)
        let now = Date.now
        let fillUps = Dictionary(vehicles.compactMap { v in v.lastFilledUp.map { (v.name, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        let stats = DrivingStats(trips: allTrips, fillUps: fillUps)
        let groups = payerGroups
        let drives = scheduled
            .filter { $0.isEnabled }
            .compactMap { d -> (WatchSyncPayload.Drive, Date)? in
                guard let dep = d.upNextDeparture(now: now) else { return nil }
                let payer = PayerGroup.resolve(key: d.paidByRaw, in: groups)
                return (WatchSyncPayload.Drive(
                    id: d.id.uuidString, title: d.title, departure: dep,
                    endName: PlaceNamer.name(for: d.endCoordinate, fallback: d.endAddress, in: savedPlaces),
                    payerKey: payer.key, payerName: payer.name,
                    payerIconName: payer.icon, payerColorName: payer.colorName), dep)
            }
            .sorted { abs($0.1.timeIntervalSince(now)) < abs($1.1.timeIntervalSince(now)) }
            .prefix(10)
            .map(\.0)
        let price = fuelPrice
        let payerStats = groups.filter { !$0.isArchived }.map { g in
            WatchSyncPayload.PayerStat(key: g.key, name: g.name, iconName: g.icon, colorName: g.colorName,
                                       cost: stats.cost(for: g.key, pricePerGallon: price))
        }
        let payload = WatchSyncPayload(
            drives: Array(drives),
            stats: .init(totalMiles: stats.totalMiles, totalDrives: stats.driveCount,
                         totalGallons: stats.totalGallons, totalSeconds: stats.totalSeconds,
                         topSpeed: stats.topSpeed, payerStats: payerStats,
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
