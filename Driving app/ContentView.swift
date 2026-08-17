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
        // A `ZStack` sibling here used to render the bar UNDER the tab bar's own bottom placement —
        // both being bottom-aligned in the same stack, the bar and the tab bar occupied nearly the
        // same ~85% of screen height, so the bar visually blended into the tab bar chrome (same
        // `.ultraThinMaterial`) and ate most of the Stats/Trips/Gas tap targets. A `.safeAreaInset`
        // attached to the `TabView` itself was tried next, but the tab bar's own bottom chrome isn't a
        // normal participant in safe-area-inset layout — it's baked into the `TabView`, so the inset
        // wasn't guaranteed to stack genuinely above it, and in practice the bar still overlapped the
        // tab bar. `.tabViewBottomAccessory` is the API the platform ships specifically for this
        // "Apple Music mini-player" placement: it docks content in the tab bar's own accessory slot,
        // above the tab bar, and keeps it there as the tab bar's height changes. `.tabBarMinimizeBehavior
        // (.never)` keeps the tab bar from shrinking on scroll, so the accessory never has to
        // renegotiate space with a tab bar whose height just changed under it.
        //
        // The `isEnabled:` parameter (not just an empty/`if`-gated content closure) matters here: the
        // system draws the accessory slot's own Liquid Glass background as soon as the modifier is
        // attached, independent of whether its content view is empty — an `if activeDrive.isMinimized
        // {...}` *inside* the closure left a fully-chrome'd, empty glass bar sitting above the tab bar
        // with no drive active. `isEnabled:` tells the system to collapse the slot itself, chrome
        // included, when there's nothing to show.
        .tabViewBottomAccessory(isEnabled: activeDrive.isMinimized) {
            if let tracker = activeDrive.tracker {
                MinimizedDriveBar(tracker: tracker) {
                    Haptics.tap()
                    activeDrive.restore()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tabBarMinimizeBehavior(.never)
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
        // Launch-only setup: seeding must run exactly once per process, not on every tab switch /
        // app-resume — a bare `.task` (not `.task(id:)`) is correct here specifically because of that.
        .task {
            PayerGroupStore.seedIfNeeded(context: modelContext)
            // Exactly one `UserSettings` row, seeded once — `SettingsView.currentSettings`'s doc
            // comment has the story: this used to be created lazily wherever it was first read,
            // which on a fresh install could insert several duplicate rows in the same frame, and
            // wherever `.first` landed after that was arbitrary.
            if (try? modelContext.fetch(FetchDescriptor<UserSettings>()))?.isEmpty ?? true {
                modelContext.insert(UserSettings())
                try? modelContext.save()
            }
            #if DEBUG
            // Manual-testing fixture — see `SampleData.seedEverythingForTesting`. Only runs when
            // explicitly launched with `UITEST_SEED=1`; never in a normal debug or release run.
            if ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" {
                SampleData.seedEverythingForTesting(context: modelContext)
            }
            #endif
        }
        // Unlike the seeding above, this genuinely needs to re-run on every resume: `syncPending`
        // previously only ever fired once at launch, so a trip saved while offline sat with its
        // `icloud.slash` badge until the user happened to pull-to-refresh or force-quit and relaunch
        // — reconnecting alone never retried it. `.task(id: activityToken)` re-fires it on every tab
        // switch and app-foreground too (`activityToken` bumps on both). Everything inside is safe to
        // repeat: `syncPending`/`backfillPaidBy` only touch what's still outstanding, and the Live
        // Activity sweep's own `recoverableSession() == nil` guard already covers "a real in-progress
        // drive is running right now" (its log file makes it "recoverable" too) regardless of how
        // many times this runs, not just at first launch.
        .task(id: activityToken) {
            await TripStore.syncPending(context: modelContext)
            await TripStore.backfillPaidBy(context: modelContext)
            #if canImport(ActivityKit) && !os(macOS)
            if LocationTracker.recoverableSession() == nil {
                await LiveActivityController.endOrphaned()
            }
            #endif
        }
        .task(id: watchSyncKey) { broadcastToWatch() }
        .onChange(of: selection) { _, _ in activityToken += 1 }
        .onChange(of: scenePhase) { old, new in
            if new == .active, old != .active { activityToken += 1; activeDrive.pushLiveUpdate() }
        }
        // The Live Activity / Watch live screen push, per `ActiveDriveController`'s doc comment —
        // driven from here (not `LiveTrackingView`) so it keeps running while a drive is minimized,
        // when that view doesn't exist. `LocationTracker` is `@Observable`; both tick while tracking.
        .onChange(of: activeDrive.tracker?.fixCount) { _, _ in activeDrive.pushLiveUpdate() }
        .onChange(of: activeDrive.tracker?.elapsedSeconds) { _, _ in activeDrive.pushLiveUpdate() }
        .fullScreenCover(isPresented: Binding(
            get: { activeDrive.isFull },
            // SwiftUI routes any system-driven dismissal (e.g. `LiveTrackingView`'s own
            // `@Environment(\.dismiss)` call when closing before a drive has started) through this
            // setter — without handling `false` here that path would desync from `activeDrive`'s own
            // state (the cover visually dismisses but `activeDrive` still thinks a drive is active).
            // Clearing mirrors what a not-yet-started drive's close button already means: there's
            // nothing to minimize, so tear the whole thing down.
            //
            // CRITICAL: SwiftUI's presentation coordinator echoes `false` back through this setter
            // once the dismiss animation completes for ANY reason — including one *we* initiated by
            // flipping `activeDrive.presentation` away from `.full` to minimize. Without the
            // `!= .minimized` guard, minimizing immediately triggers this "confirmation" callback,
            // which called `clear()` and destroyed the very drive the user just tried to minimize —
            // dropping the tracker and the Live Activity with no way back. Only a dismissal that
            // *isn't* an intentional minimize should tear the drive down.
            set: { presented in
                guard !presented, activeDrive.presentation != .minimized else { return }
                activeDrive.clear()
            }
        )) {
            if let tracker = activeDrive.tracker {
                // Re-applied explicitly: `.environment(activeDrive)` above (on the ZStack) normally
                // propagates into this cover's content, but `LiveTrackingView`'s own top-level
                // `NavigationStack` resolves its destinations through a code path that doesn't
                // reliably see environment values inherited across a fullScreenCover boundary —
                // without this, `LiveTrackingView`'s `@Environment(ActiveDriveController.self)` read
                // crashes instantly with "No Observable object of type ActiveDriveController found."
                LiveTrackingView(tracker: tracker, scheduled: activeDrive.context.scheduled,
                                 asModal: activeDrive.context.asModal, goTo: activeDrive.context.goTo,
                                 onFinish: { activeDrive.clear(); watchStart = nil; selection = .drive })
                    .environment(activeDrive)
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
            // The guard the doc comment above already promises, but never actually implemented:
            // a drive already active (possibly for a different schedule) must not be silently
            // swapped out — `start(scheduled:)` would just hand back the existing tracker and this
            // tap would appear to do nothing. Surface the real in-progress drive instead.
            if activeDrive.hasActiveDrive, activeDrive.context.scheduled?.id != drive.id {
                activeDrive.restore()
            } else {
                activeDrive.start(scheduled: drive)
            }
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
