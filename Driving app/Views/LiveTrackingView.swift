import SwiftUI
import MapKit
import SwiftData

/// A lightweight ad-hoc destination for the "Go to" feature: navigate to a saved place with a
/// computed ETA and on-time grading, recorded as a normal trip. This is a third way to start a
/// drive — separate from ad-hoc "Start a Drive" and scheduled drives.
struct QuickTrip: Identifiable {
    let id = UUID()
    var name: String
    var coordinate: CLLocationCoordinate2D
    /// Predicted travel seconds. Nil when no ETA could be fetched (offline / no location) — then the
    /// drive still records, just without on-time grading. The scheduled departure/arrival are
    /// anchored when tracking actually starts, so the ETA-fetch latency never skews the delay.
    var travelSeconds: Int?
    var category: TripCategory = .errand
    var paidBy: String = PayerGroup.selfKey
    var vehicleName: String?
}

struct LiveTrackingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ActiveDriveController.self) private var activeDrive
    @Query private var vehicles: [Vehicle]
    @Query private var settingsList: [UserSettings]

    /// When launched from a scheduled drive, the view runs modally and pre-loads the destination.
    let scheduled: ScheduledDrive?

    /// When launched from a "Go to" saved place, auto-starts navigation to it with a computed ETA.
    let goTo: QuickTrip?

    /// Presented as a full-screen cover from the Drive tab (ad-hoc "Start a Drive"). Adds a close
    /// button and dismisses on finish, exactly like a scheduled modal drive.
    let asModal: Bool

    /// Called after the cover is dismissed (saved or discarded) so the presenter can tear it down.
    var onFinish: (() -> Void)?

    /// Owned by `ActiveDriveController` (not this view) so it survives being minimized: dismissing
    /// this view's full-screen cover no longer deallocates it — the same instance is handed back the
    /// next time the cover is presented, whether that's a fresh start or a restore from minimized.
    let tracker: LocationTracker
    @State private var selectedVehicle: Vehicle?
    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var followUser = true
    /// The map camera's current heading (degrees from north) — drives the custom compass below.
    @State private var mapHeading: Double = 0
    @State private var showingSummary = false
    @State private var showingVehiclePicker = false
    @State private var showingAddStop = false
    @State private var showingDivertSearch = false
    @State private var recovered: DriveLogger.Recovered?
    @State private var confirmDiscardRecovered = false
    /// Measured height of `bottomControls`, so `recenterButton` can sit just above it regardless of
    /// which of its several states (pre-start / paused / mid-route-with-fuel-chip / …) is showing.
    @State private var bottomControlsHeight: CGFloat = 160
    @State private var didAutoStart = false
    /// Bottom edge (screen coordinates) of the stats/turn cards stacked at the top. The map keeps that
    /// much of its top covered so the car's marker sits in the VISIBLE middle, not under the cards.
    @State private var topCoverHeight: CGFloat = 0
    /// Thinned copy of the recorded track, grown incrementally (see `TrailCache`).
    @State private var trail = TrailCache()

    /// The dotted light-blue guide line + next-turn data. Owned by `ActiveDriveController` so it keeps
    /// refreshing (and feeding the Watch / Live Activity) while this view is minimized.
    private var guide: GuideRoute { activeDrive.guide }

    /// Designated init: used by `ContentView`'s single shared full-screen cover, which always has a
    /// tracker on hand via `ActiveDriveController` (fresh for a new drive, or the same instance
    /// again when restoring from minimized).
    init(tracker: LocationTracker, scheduled: ScheduledDrive? = nil, asModal: Bool = false,
         goTo: QuickTrip? = nil, onFinish: (() -> Void)? = nil) {
        self.tracker = tracker
        self.scheduled = scheduled
        self.asModal = asModal
        self.goTo = goTo
        self.onFinish = onFinish
    }

    /// Convenience init that creates its own tracker — for standalone use outside the
    /// controller-managed production flow (debug screenshots; a future SwiftUI preview).
    init(scheduled: ScheduledDrive? = nil, asModal: Bool = false, goTo: QuickTrip? = nil, onFinish: (() -> Void)? = nil) {
        self.init(tracker: LocationTracker(), scheduled: scheduled, asModal: asModal, goTo: goTo, onFinish: onFinish)
    }

    #if DEBUG
    init(previewTracker: LocationTracker) {
        self.init(tracker: previewTracker)
    }
    #endif

    private var isModal: Bool { scheduled != nil || asModal || goTo != nil }

    private var navTitle: String {
        if tracker.isTracking { return "Tracking" }
        if isModal { return scheduled?.title ?? goTo.map { "To \($0.name)" } ?? "Drive" }
        return "Track Drive"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapLayer

                VStack(spacing: 12) {
                    VStack(spacing: 12) {
                        if let recovered, !tracker.isTracking {
                            recoveryBanner(recovered)
                        }
                        if tracker.isTracking {
                            if tracker.isMultiLeg, tracker.hasActiveTarget {
                                legProgressStrip
                            }
                            unifiedHUD
                            nextTurnBanner
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topCoverHeight = $0 }
                    Spacer()
                    bottomControls
                }
                .padding()

                recenterButton
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // While tracking, the leading button minimizes (the drive keeps recording) instead of
                // closing — closing-while-tracking used to stop the drive, which would now conflict
                // with minimize being the "leave the screen" affordance. Before a drive has actually
                // started, it still just closes.
                if isModal {
                    ToolbarItem(placement: .cancellationAction) {
                        if tracker.isTracking {
                            Button { Haptics.tap(); activeDrive.minimize() } label: {
                                Image(systemName: "chevron.down")
                            }
                            .accessibilityLabel("Minimize")
                        } else {
                            Button { stopIfNeededAndDismiss() } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("Close")
                        }
                    }
                }
            }
            .onAppear {
                setup()
                if followUser, tracker.currentLocation != nil { cameraPosition = followCameraPosition() }
            }
            // Bring CoreLocation up off the first-render path so the tab appears instantly the
            // first time; the map's user dot fills in a moment later. Also re-runs (harmlessly) every
            // time this view is reconstructed — e.g. restoring from minimized — since
            // `configureIfNeeded()`/permission-request inside are already no-ops past the first call.
            .task { tracker.activateIdle() }
            // Watch remote-control (end drive / arrive at stop / start next leg) is handled by
            // `ContentView` via `ActiveDriveController`, not here — those must keep working even
            // while this view doesn't exist (minimized), so they can't live on a view's own
            // `.onReceive`. `setup()` picks up the result (e.g. a watch-triggered end while minimized)
            // when this view reappears.
            .sheet(isPresented: $showingSummary) {
                TripSummaryView(tracker: tracker, vehicle: selectedVehicle,
                                initialPaidBy: tracker.plannedPaidBy,
                                onSave: saveTrip, onDiscard: discardTrip)
                    // Force an explicit Save or Discard: a swipe-dismiss would end the drive without
                    // running either handler, silently losing the trip and leaving a scheduled
                    // occurrence stuck showing DEPARTED (its finish never recorded).
                    .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showingVehiclePicker) {
                VehiclePickerSheet(vehicles: vehicles, selected: $selectedVehicle)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingAddStop) {
                LocationSearchSheet(title: addStopSheetTitle) { picked in
                    Haptics.tap()
                    let stop = RouteStop(address: picked.address, coordinate: picked.coordinate)
                    if !tracker.isTracking {
                        // Pre-start "Set destination" / "Tap to change": this is the single ad-hoc
                        // destination, not a growing stop list — `appendLiveStop` would INSERT ahead
                        // of whatever was already picked instead of replacing it, silently turning
                        // "change my destination" into a 2-stop route via the discarded old one.
                        tracker.setRoute(stops: [], finalDestination: picked.coordinate, finalName: picked.address)
                    } else {
                        // `legProgressStrip` only appears `if tracker.isMultiLeg` — adding the first
                        // stop to an open/single-destination drive flips that false→true right here,
                        // which (unlike starting/stopping the drive, both already wrapped) wasn't
                        // animated: the strip popped in and shoved the HUD down with no transition.
                        withAnimation(.spring(duration: 0.3)) { tracker.appendLiveStop(stop) }
                    }
                    guide.invalidate()
                    guide.refresh(tracker: tracker)
                    activeDrive.pushLiveUpdate()
                }
            }
            .sheet(isPresented: $showingDivertSearch) {
                LocationSearchSheet(title: "Divert To") { picked in
                    Haptics.tap()
                    divert(to: RouteStop(address: picked.address, coordinate: picked.coordinate))
                }
            }
        }
    }

    // MARK: - Setup / scheduled start

    private func setup() {
        // Permission + location startup happen in `.task` (activateIdle) to keep first render cheap.
        if selectedVehicle == nil {
            // Prefer the tracker's own record over the launch context: on a restore-from-minimized
            // (or a watch-triggered end bringing the full view back), `scheduled`/`goTo` still
            // reflect the ORIGINAL start intent, but `tracker.plannedVehicleName` reflects what's
            // actually been recorded so far — the more reliable source once a drive is under way.
            let wantedVehicle = tracker.plannedVehicleName ?? scheduled?.vehicleName ?? goTo?.vehicleName
            if let wantedVehicle {
                // A name was actually specified (from a schedule/Go-to/resumed tracker) — if it
                // doesn't match any current vehicle (e.g. the car was renamed elsewhere and this
                // schedule's reference is stale), falling back to `vehicles.first` used to silently
                // start the drive recording against WHATEVER OTHER car happened to be first — wrong
                // MPG, wrong fuel estimate, wrong car on the saved trip. Leave it unresolved instead;
                // the picker still lets the user set the right one before starting.
                selectedVehicle = vehicles.first(where: { $0.name == wantedVehicle })
            } else {
                // No vehicle was ever specified (e.g. an ad-hoc "Start a Drive") — defaulting to the
                // first car on file is a reasonable, honest default here, not a silent wrong guess.
                selectedVehicle = vehicles.first
            }
        }
        // Everything below (recovery check, default-payer seed, auto-start) is once-only setup for a
        // BRAND NEW drive. `tracker.startTime` — set only once `startTracking()`/`resume(from:)`
        // actually runs — is the reliable signal for that, unlike this view's own `@State` (including
        // `didAutoStart`): minimizing dismisses this view's full-screen cover, which tears down all of
        // its `@State`, so restoring (or a watch-triggered end bringing the full view back to show its
        // summary) reconstructs a fresh view whose `didAutoStart` would incorrectly read `false` again
        // even though the drive has been running (or just finished) the whole time. `tracker` itself,
        // by contrast, survives minimize/restore (see the `tracker` property's doc comment).
        guard tracker.startTime == nil else {
            if tracker.isTracking {
                // Already under way — resync what a freshly (re)constructed view needs instead of
                // waiting on the next location fix.
                guide.invalidate()
                guide.refresh(tracker: tracker)
                activeDrive.pushLiveUpdate()
            } else if !tracker.points.isEmpty, !showingSummary {
                // Stopped but never shown its summary — e.g. a watch-triggered "End Drive" that fired
                // while this view was minimized (see `ActiveDriveController.handleEndFromWatch`).
                presentSummaryOrAutoSave()
            }
            return
        }
        // A scheduled or "Go to" drive starts a fresh auto-started session; only an ad-hoc drive
        // (Track / Start a Drive) offers to recover an interrupted session first.
        if scheduled == nil, goTo == nil {
            recovered = LocationTracker.recoverableSession()
            // Seed the payer from the user's default for non-scheduled drives (a recovered session
            // overrides this with its own saved payer when resumed).
            tracker.plannedPaidBy = settingsList.first?.defaultPaidByRaw ?? PayerGroup.selfKey
        }
        // Auto-start a "Go to" drive once, pre-loaded with its destination & computed ETA so it
        // grades on-time exactly like a scheduled drive — but without touching the schedule.
        if let goTo, !didAutoStart {
            didAutoStart = true
            tracker.setRoute(stops: [], finalDestination: goTo.coordinate, finalName: goTo.name)
            tracker.tripName = "To \(goTo.name)"
            // Anchor departure/arrival at the actual start instant so the ETA-fetch latency doesn't
            // skew the recorded delay; arrival = start + predicted travel (nil ETA → ungraded).
            let start = Date()
            tracker.scheduledDeparture = start
            tracker.scheduledArrival = goTo.travelSeconds.map { start.addingTimeInterval(TimeInterval($0)) }
            tracker.plannedCategory = goTo.category
            tracker.plannedPaidBy = goTo.paidBy
            tracker.plannedVehicleName = goTo.vehicleName
            startTracking()
        }
        // Auto-start a scheduled drive once, pre-loaded with its destination & schedule timing.
        if let scheduled, !didAutoStart {
            didAutoStart = true
            // Build the leg targets (stops → destination) so a multi-stop schedule advances leg by leg.
            tracker.setRoute(stops: scheduled.stops,
                             finalDestination: scheduled.endCoordinate,
                             finalName: scheduled.endAddress)
            tracker.tripName = scheduled.title
            // The occurrence happening today: the schedule's departure & arrival times-of-day on
            // today's date. (Computing these directly avoids the delay being read as the full
            // travel time.)
            let cal = Calendar.current
            let today = Date()
            let depT = cal.dateComponents([.hour, .minute], from: scheduled.departure)
            let arrT = cal.dateComponents([.hour, .minute], from: scheduled.scheduledArrival)
            let schedDep = cal.date(bySettingHour: depT.hour ?? 0, minute: depT.minute ?? 0, second: 0, of: today) ?? today
            var schedArr = cal.date(bySettingHour: arrT.hour ?? 0, minute: arrT.minute ?? 0, second: 0, of: today) ?? today
            if schedArr < schedDep { schedArr = cal.date(byAdding: .day, value: 1, to: schedArr) ?? schedArr }  // overnight
            tracker.scheduledDeparture = schedDep
            tracker.scheduledArrival = schedArr
            tracker.plannedCategory = scheduled.category
            tracker.plannedPaidBy = scheduled.paidByRaw
            tracker.plannedVehicleName = scheduled.vehicleName
            // Mark this occurrence as departed for the departures board.
            scheduled.lastStartedAt = .now
            try? context.save()
            startTracking()
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            // Guide route ahead — the focal "where to drive" element while a drive is under way: a
            // vivid sky-cyan (deliberately a different hue from the traveled track's plain blue, not
            // just a faint dotted variant of it) with bold, legible dashes rather than a near-invisible
            // dotted trace. Drawn first so the traveled track sits on top of it; the two rarely overlap
            // in practice since one trails behind the current position and the other leads ahead of it.
            // Also drawn BEFORE the drive starts once a destination is set, as a route preview.
            if guide.coordinates.count >= 2 {
                MapPolyline(coordinates: guide.coordinates)
                    .stroke(Color.driveGuideRoute,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: [3, 11]))
            }

            // Traveled track — the actual recorded drive, this app's core record. Slightly receded
            // (vs. full-opacity blue) so the guide route ahead reads as the primary "what to do next"
            // element while actively driving, without losing visibility of where you've been.
            let traveled = trail.coordinates(for: tracker.points)
            if traveled.count >= 2 {
                MapPolyline(coordinates: traveled)
                    .stroke(.blue.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = tracker.startCoordinate, tracker.isTracking {
                Annotation("Start", coordinate: start) {
                    Circle().fill(.green).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            // Multi-leg: draw every intermediate stop — reached ones checked green, upcoming ones
            // dimmed & numbered — plus the final destination pin.
            ForEach(Array(tracker.legTargets.enumerated()), id: \.element.id) { i, target in
                if i < tracker.legTargets.count - 1 || !tracker.hasActiveTarget {
                    Annotation(target.address.isEmpty ? "Stop \(i + 1)" : target.address,
                               coordinate: target.coordinate) {
                        legStopPin(index: i)
                    }
                }
            }
            if tracker.hasActiveTarget, let dest = tracker.legTargets.last?.coordinate ?? tracker.destination {
                Annotation(tracker.finalDestinationName ?? tracker.destinationName ?? "Destination", coordinate: dest) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        // The system compass/user-location controls anchor to the top safe area — directly underneath
        // the leg strip and stats HUD this screen stacks there, so they were drawn behind (or poking
        // out of) those cards. Hidden in favour of `compassButton` / `recenterButton` at the bottom.
        .mapControls { }
        // Keep MapKit's logo / Legal link (and the camera's visual centre) clear of the bottom
        // controls, which used to be drawn directly over them.
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomControlsHeight + 8) }
        // Same for the top: the stats + next-turn cards cover the upper part of the map, so the camera's
        // visual centre (where the car sits) is the middle of what's actually visible.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: max(0, topCoverHeight + 8)) }
        // The very first location fix: set the (zoomed-out) follow camera right away. Waiting for a
        // fix COUNT change left the pre-start map on MapKit's default street-level zoom until the phone
        // moved, which it never does while parked.
        .onChange(of: tracker.currentLocation != nil) { _, known in
            if known, followUser { cameraPosition = followCameraPosition() }
        }
        // `.onEnd`, not `.continuous`: a continuous callback writes @State on every frame of a pan/pinch,
        // re-evaluating this whole view (and its big polylines) mid-gesture — the lag on first touch.
        .onMapCameraChange(frequency: .onEnd) { ctx in mapHeading = ctx.camera.heading }
        // Apple-Maps behavior: panning or pinching the map breaks the follow lock; the recenter
        // button re-engages it.
        .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in
            if followUser { followUser = false }
        })
        .simultaneousGesture(MagnifyGesture().onChanged { _ in
            if followUser { followUser = false }
        })
        // Observe the per-fix counter, not just latitude — a stationary car (or one heading due
        // east/west) delivers fixes with an unchanged latitude, which would otherwise stall the
        // follow camera and guide-route refresh. The Live Activity/watch push itself is driven from
        // `ContentView` (see `ActiveDriveController`), not here, so it keeps running even while this
        // view is dismissed (minimized) — observing the same `fixCount`/`elapsedSeconds` here too
        // would just be a redundant duplicate push while this view happens to be on screen.
        .onChange(of: tracker.fixCount) { _, _ in
            if followUser, let loc = tracker.currentLocation {
                // `cameraPosition` starts (and `startTracking()`/`resumeRecovered()` reset it) as
                // `.userLocation(followsHeading: true, …)` — heading-up rotation — but this very
                // first per-fix write always replaced it with a plain, un-rotated `.region`, so
                // heading-up follow was never actually in effect for a single second of a real
                // drive. Only rotate to the GPS course when it's both valid (`-1` marks "no course")
                // AND the car is actually moving fast enough for it to be meaningful — course from
                // slow/near-stationary fixes is mostly GPS noise, and spinning the map at every red
                // light would be worse than the north-up camera this replaces. `withAnimation` turns
                // the previous unanimated ~1 Hz "ratchet" (every other camera write in this view,
                // e.g. `recenterButton`'s, is already animated) into a smooth glide.
                let heading = (tracker.currentCourse >= 0 && tracker.currentSpeed > 5) ? tracker.currentCourse : 0
                withAnimation(.linear(duration: 0.9)) {
                    cameraPosition = .camera(MapCamera(centerCoordinate: loc, distance: followDistance,
                                                       heading: heading, pitch: 0))
                }
            }
            guide.refresh(tracker: tracker)
        }
        // Every IN-APP action that changes the leg target (arrivedButton, "Start Next Trip", adding
        // a stop, `setup()`'s resync) resets `lastRouteFetchFrom` itself before calling
        // `guide.refresh(tracker: tracker)`. `ActiveDriveController.handleArriveFromWatch`/
        // `handleStartNextLegFromWatch` change the SAME `currentLegIndex` from a watch tap, but go
        // through the model, not this view — so without observing it here too, the 250m throttle in
        // `refreshEfficientRoute` (keyed off the OLD leg's last fetch point) kept the guide line
        // pointing at the stop just left until the car had driven 250m past it.
        .onChange(of: tracker.currentLegIndex) { _, _ in
            guide.invalidate()
            guide.clear()
            tracker.appleMapsExpectedTravelTime = nil
            tracker.appleMapsTravelTimeFetchDate = nil
            guide.refresh(tracker: tracker)
        }
        .ignoresSafeArea(edges: .top)
    }

    /// A numbered pin for an intermediate stop: green + checkmark once reached, dimmed & numbered
    /// while still upcoming, highlighted when it's the current leg's target.
    private func legStopPin(index: Int) -> some View {
        let reached = index < tracker.currentLegIndex
        let isCurrent = index == tracker.currentLegIndex
        return ZStack {
            Circle()
                .fill(reached ? Color.green : (isCurrent ? Color.red : Color.gray))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            if reached {
                Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
            } else {
                Text("\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white)
            }
        }
        .opacity(reached ? 0.85 : (isCurrent ? 1 : 0.7))
    }

    // MARK: - Leg progress strip

    /// A compact route timeline across the top: Start ● — ① — ② — ⚑, with reached stops checked,
    /// the current leg highlighted, and a live "Leg 2 of 3 · next: Grocery" caption. Tapping the
    /// plus adds a stop mid-drive.
    private var legProgressStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                legNode(icon: "flag.fill", filled: true, tint: .green)  // Start
                ForEach(Array(tracker.legTargets.enumerated()), id: \.element.id) { i, _ in
                    legConnector(active: i < tracker.currentLegIndex)
                    if i < tracker.legTargets.count - 1 {
                        legNode(number: i + 1,
                                filled: i < tracker.currentLegIndex,
                                highlighted: i == tracker.currentLegIndex,
                                tint: i < tracker.currentLegIndex ? .green : (i == tracker.currentLegIndex ? .red : .gray))
                    } else {
                        legNode(icon: "mappin", filled: tracker.isOnFinalLeg,
                                highlighted: tracker.isOnFinalLeg, tint: tracker.isOnFinalLeg ? .red : .gray)
                    }
                }
                Spacer(minLength: 8)
                Button { Haptics.tap(); showingAddStop = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.blue)
                }
                .accessibilityLabel("Add stop")
            }
            HStack {
                Text("Leg \(min(tracker.currentLegIndex + 1, tracker.totalLegs)) of \(tracker.totalLegs)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                if let next = tracker.currentLegTarget, !next.address.isEmpty {
                    Text("· next: \(next.address)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func legNode(icon: String? = nil, number: Int? = nil, filled: Bool, highlighted: Bool = false, tint: Color) -> some View {
        ZStack {
            // The current leg's node (highlighted) is tinted even though it isn't "filled/checked" yet,
            // so it reads distinctly from the dim upcoming nodes.
            Circle().fill(filled || highlighted ? tint : Color.gray.opacity(0.4)).frame(width: 20, height: 20)
            if filled, number != nil {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else if let number {
                Text("\(number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
        }
    }

    private func legConnector(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.green : Color.gray.opacity(0.4))
            .frame(height: 2).frame(maxWidth: .infinity)
            .padding(.horizontal, 2)
    }

    /// Custom recenter button — bottom-trailing, clear of the status-bar clock (fixes the old
    /// control that sat in the top corner underneath the time). Its bottom offset tracks
    /// `bottomControlsHeight` (measured off the actual controls, see `bottomControls`) rather than a
    /// fixed value — `bottomControls` is far taller than a hardcoded 160pt in three of its four
    /// states (pre-start, paused-between-legs, mid-route with a fuel estimate chip), so the button
    /// sat on top of — and stole taps from — whatever was underneath it: the destination row's
    /// chevron pre-start, the leg recap's mileage while paused, the fuel chip mid-route.
    /// How far out the follow camera sits (metres). Roughly 2.5× further than before, and it pulls back
    /// as speed rises so a few blocks of road ahead stay visible at highway speed.
    private var followDistance: Double {
        // Frame roughly the next ~75 s of travel (never less than ~500 m), but no further than what's
        // actually left of the route — so approaching the destination or a turn, the map tightens
        // enough to read, while at highway speed it pulls back to show what's coming. The camera sits
        // ~2.6× the framed length away (its visible window is about that much taller than the camera
        // distance), clamped to a readable 1.8–7 km.
        let mps = max(tracker.currentSpeed, 0) * 0.44704
        var lookahead = max(500, mps * 75)
        if let remaining = guide.remainingMeters ?? tracker.legRemainingMiles.map({ $0 / 1.3 * 1609.34 }) {
            lookahead = min(lookahead, max(remaining, 450))
        }
        return min(max(lookahead * 2.6, 1800), 7000)
    }

    /// Camera centred on the user at the zoomed-out follow distance (falls back to MapKit's own
    /// user-location camera until the first fix arrives).
    private func followCameraPosition() -> MapCameraPosition {
        guard let loc = tracker.currentLocation else {
            return .userLocation(followsHeading: true, fallback: .automatic)
        }
        return .camera(MapCamera(centerCoordinate: loc, distance: followDistance, heading: 0, pitch: 0))
    }

    /// Zoom out so the whole drive fits: where you've been, the guide line ahead, every stop and the
    /// destination. Releases the follow lock (tap the location button to go back to following).
    private func fitWholeRoute() {
        var pts = trail.coordinates(for: tracker.points)
        pts.append(contentsOf: guide.coordinates)
        pts.append(contentsOf: tracker.legTargets.map(\.coordinate))
        if let loc = tracker.currentLocation { pts.append(loc) }
        if let d = tracker.destination { pts.append(d) }
        pts = pts.filter(\.isUsableCoordinate)
        guard !pts.isEmpty else { return }
        var rect = MKMapRect.null
        for c in pts { rect = rect.union(MKMapRect(origin: MKMapPoint(c), size: MKMapSize(width: 0, height: 0))) }
        // Breathing room, and a floor so a short drive isn't zoomed to a single street.
        let pad = max(rect.width, rect.height) * 0.18
        rect = rect.insetBy(dx: -max(pad, 900), dy: -max(pad, 900))
        followUser = false
        withAnimation(.easeInOut(duration: 0.5)) { cameraPosition = .rect(rect) }
    }

    /// Appears only while the map is rotated (like the system compass); tap to snap back to north-up.
    @ViewBuilder
    private var compassButton: some View {
        if abs(mapHeading.truncatingRemainder(dividingBy: 360)) > 1 {
            Button {
                Haptics.tap()
                followUser = false
                let center = tracker.currentLocation ?? .init(latitude: 0, longitude: 0)
                withAnimation(.easeInOut(duration: 0.4)) {
                    cameraPosition = .camera(MapCamera(centerCoordinate: center, distance: followDistance,
                                                       heading: 0, pitch: 0))
                }
            } label: {
                Image(systemName: "location.north.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .rotationEffect(.degrees(-mapHeading))
                    .padding(12)
                    .background(.ultraThinMaterial, in: .circle)
                    .shadow(radius: 4, y: 2)
            }
            .accessibilityLabel("Compass — reset to north")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var recenterButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 10) {
                compassButton
                if tracker.isTracking {
                    Button { Haptics.tap(); fitWholeRoute() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .padding(12)
                            .background(.ultraThinMaterial, in: .circle)
                            .shadow(radius: 4, y: 2)
                    }
                    .accessibilityLabel("Show entire route")
                }
                Button {
                    followUser = true
                    if let loc = tracker.currentLocation {
                        withAnimation { cameraPosition = .camera(MapCamera(
                            centerCoordinate: loc, distance: followDistance, heading: 0, pitch: 0)) }
                    } else {
                        cameraPosition = followCameraPosition()
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .padding(12)
                        .background(.ultraThinMaterial, in: .circle)
                        .shadow(radius: 4, y: 2)
                }
                .accessibilityLabel("Recenter on my location")
                }
                .padding(.trailing, 20)
                .padding(.bottom, bottomControlsHeight + 12)
            }
        }
    }

    // MARK: - Stats HUD

    private var unifiedHUD: some View {
        VStack(spacing: 10) {
            // Main driving stats: distance, time, speed
            HStack(spacing: 0) {
                statItem(value: String(format: "%.1f", tracker.distanceMiles), unit: "mi",
                         icon: "point.topleft.down.to.point.bottomright.curvepath.fill")
                Divider().frame(height: 28)
                statItem(value: tracker.formattedElapsed(), unit: "time", icon: "clock.fill")
                Divider().frame(height: 28)
                statItem(value: String(format: "%.0f", tracker.currentSpeed), unit: "mph", icon: "speedometer")
            }
            
            // ETA + on-time status (only if routed and not paused between legs)
            if tracker.destination != nil, !tracker.isPausedBetweenLegs {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tracker.isMultiLeg ? "ETA (final)" : "ETA")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let eta = tracker.etaDate {
                            Text(eta, format: .dateTime.hour().minute())
                                .font(.headline).fontWeight(.bold).fontDesign(.rounded)
                        } else {
                            Text("—").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if tracker.scheduledArrival != nil {
                        if let delay = tracker.delaySeconds {
                            StatusChip(status: .live(delaySeconds: delay))
                        } else {
                            StatusChip(status: .liveEnRoute)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The next maneuver on the guide route ("Turn left onto Main St · 0.3 mi").
    @ViewBuilder
    private var nextTurnBanner: some View {
        if let turn = guide.nextTurn, !tracker.isPausedBetweenLegs {
            HStack(spacing: 12) {
                Image(systemName: turnSymbol(for: turn))
                    .font(.title2.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.gradient, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    if let m = guide.nextTurnMeters {
                        Text(GuideRoute.distanceLabel(m)).font(.headline).fontDesign(.rounded)
                    }
                    Text(turn).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// SF Symbol for a maneuver, from the instruction text.
    private func turnSymbol(for text: String) -> String {
        let t = text.lowercased()
        if t.contains("u-turn") { return "arrow.uturn.left" }
        if t.contains("left") { return t.contains("slight") || t.contains("bear") ? "arrow.up.left" : "arrow.turn.up.left" }
        if t.contains("right") { return t.contains("slight") || t.contains("bear") ? "arrow.up.right" : "arrow.turn.up.right" }
        if t.contains("arrive") || t.contains("destination") { return "mappin.circle.fill" }
        if t.contains("merge") || t.contains("exit") || t.contains("ramp") { return "arrow.merge" }
        return "arrow.up"
    }

    private func statItem(value: String, unit: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).fontWeight(.bold).fontDesign(.rounded)
                .contentTransition(.numericText())
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Recovery banner

    private func recoveryBanner(_ rec: DriveLogger.Recovered) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unsaved drive recovered").font(.subheadline.weight(.semibold))
                Text("\(rec.points.count) points · interrupted drive").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 6) {
                // A recovered multi-leg drive can be resumed and continued, not just saved.
                let resumable = rec.meta.isPaused || !rec.meta.legTargets.isEmpty
                if resumable {
                    Button("Resume") { resumeRecovered(rec) }
                        .font(.caption.weight(.bold)).buttonStyle(.borderedProminent)
                    Button("Save") { startSaveRecovered(rec) }
                        .font(.caption.weight(.bold)).buttonStyle(.bordered)
                } else {
                    Button("Save") { startSaveRecovered(rec) }
                        .font(.caption.weight(.bold)).buttonStyle(.borderedProminent)
                }
            }
            Button { confirmDiscardRecovered = true } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .accessibilityLabel("Discard recovered drive")
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        // One mis-tap used to throw the whole unsaved track away, with no way back — and this
        // banner shows up right after a crash, exactly when people poke at things.
        .confirmationDialog("Discard the recovered drive?", isPresented: $confirmDiscardRecovered,
                            titleVisibility: .visible) {
            Button("Discard \(rec.points.count) Points", role: .destructive) {
                LocationTracker.discardRecoverableSession()
                recovered = nil
                // This recovered session belongs to a previous process that force-quit before
                // calling `end()` — nothing in THIS process's `LiveActivityController` knows about
                // it, so the normal `activeDrive.endLiveActivity()` path (which only acts on an
                // in-memory reference) can't clean it up. Sweep orphans directly instead.
                #if canImport(ActivityKit) && !os(macOS)
                Task { await LiveActivityController.endOrphaned() }
                #endif
            }
        } message: {
            Text("The GPS track from the interrupted drive will be deleted. Save it instead to keep it.")
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Optional destination for an ad-hoc drive, set before starting: the drive then routes
            // toward it with a live ETA — a destination on a non-scheduled route, no schedule needed.
            if !tracker.isTracking, recovered == nil, scheduled == nil {
                destinationRow
            }
            if let vehicle = selectedVehicle, !tracker.isTracking {
                vehicleChip(vehicle)
            }
            if tracker.isTracking {
                if tracker.isPausedBetweenLegs {
                    pausedControls
                } else {
                    if let mpg = selectedVehicle?.avgMpg, mpg > 0 {
                        let gallons = tracker.accumulatedGallons
                        HStack {
                            Image(systemName: "fuelpump.fill").foregroundStyle(.orange)
                            Text(String(format: "Est. %.2f gal used", gallons)).font(.subheadline).fontWeight(.medium)
                            Text(String(format: "(%.0f MPG)", mpg)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
                    }
                    // Mid-route legs get an "Arrived" primary that advances; the final leg ends the drive.
                    if tracker.isMultiLeg, !tracker.isOnFinalLeg {
                        arrivedButton
                        HStack(spacing: 8) {
                            divertMenu(compact: false)
                            endDriveButton(prominent: false)
                        }
                    } else {
                        // A plain open or single-destination drive can still gain a destination or a
                        // stop on the fly — adding one turns it into a linked multi-stop journey.
                        if tracker.hasActiveTarget {
                            HStack(spacing: 8) {
                                addStopButton
                                divertMenu(compact: false)
                            }
                        } else {
                            addStopButton
                        }
                        stopButton
                    }
                }
            } else if recovered != nil {
                // A recovered drive is pending above. Starting a fresh drive would overwrite its
                // unsaved log, so require Save / Resume / Discard first.
                Text("Resolve the recovered drive above before starting a new one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
            } else {
                startButton
            }
        }
        // Feeds `recenterButton`'s bottom offset — see its own doc comment for why a fixed offset
        // was wrong here.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomControlsHeight = $0 }
    }

    /// Shown while parked between legs. Frames the stretch you just finished as its own completed,
    /// linked trip — with a mini recap — and the next leg as a new trip, so a multi-stop drive reads
    /// as separate linked trips rather than one long drive with pauses.
    private var pausedControls: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Leg \(tracker.reachedStopCount) complete").font(.subheadline.weight(.semibold))
                        Text("Logged as a separate linked trip").font(.caption2).foregroundStyle(.secondary)
                        connectionTimer
                    }
                    Spacer()
                    if let s = tracker.lastLegStats {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.1f mi", s.miles))
                                .font(.subheadline.weight(.bold)).fontDesign(.rounded)
                            Text(legDurationString(s.seconds)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let next = tracker.currentLegTarget {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.blue)
                        Text("Next trip → \(next.address.isEmpty ? "Destination" : next.address)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))

            Button {
                Haptics.rigid()
                withAnimation(.spring(duration: 0.4)) { tracker.startNextLeg() }
                followUser = true
                guide.invalidate()
                guide.refresh(tracker: tracker)
                activeDrive.pushLiveUpdate()
            } label: {
                controlLabel(!tracker.hasActiveTarget ? "Resume Driving"
                             : (tracker.isOnFinalLeg ? "Start Final Leg" : "Start Next Trip"),
                             "location.fill", .blue)
            }

            HStack(spacing: 8) {
                Button { Haptics.tap(); showingAddStop = true } label: {
                    Label("Add stop", systemImage: "plus")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.blue)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.systemGray6), in: .capsule)
                }
                if tracker.hasActiveTarget { divertMenu(compact: true) }
                Button { Haptics.rigid(); endDrive() } label: {
                    Label("End drive", systemImage: "stop.fill")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.systemGray6), in: .capsule)
                }
            }
        }
    }

    private var arrivedButton: some View {
        Button {
            Haptics.success()
            withAnimation(.spring(duration: 0.4)) { tracker.arriveAtCurrentStop() }
            // The target advanced to the next stop — re-route the guide line to it.
            guide.invalidate()
            guide.refresh(tracker: tracker)
            activeDrive.pushLiveUpdate()
        } label: {
            let name = tracker.currentLegTarget?.address
            controlLabel(name?.isEmpty == false ? "Arrived — Next Stop" : "Arrived at Stop", "checkmark.circle.fill", .green)
        }
    }

    private func endDriveButton(prominent: Bool) -> some View {
        Button { Haptics.rigid(); endDrive() } label: {
            Text("End drive")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color(.systemGray6), in: .capsule)
        }
    }

    /// End the whole drive now (from any leg) → summary. Pushes a terminal Live Activity/Watch frame
    /// right away — independent of whether the user goes on to Save or Discard in the summary sheet,
    /// the physical drive is over the instant this fires, and the activity shouldn't keep reading
    /// "On the way" while they're filling in the category/notes.
    private func endDrive() {
        withAnimation(.spring(duration: 0.4)) { tracker.stopTracking() }
        activeDrive.endLiveActivityWithFinalState()
        activeDrive.endLiveBroadcast()
        presentSummaryOrAutoSave()
    }

    /// Show the "Trip Complete" sheet — unless the user turned it off in Settings ("Don't show
    /// again"), in which case save straight away with the drive's planned category and payer.
    private func presentSummaryOrAutoSave() {
        if settingsList.first?.skipTripSummary == true {
            saveTrip(category: tracker.plannedCategory, paidBy: tracker.plannedPaidBy, notes: nil)
        } else {
            showingSummary = true
        }
    }

    /// Live connection timer shown while parked at a stop — time since arrival, flagged once the
    /// stop is long enough that it'll be saved as the end of the trip rather than a connection.
    @ViewBuilder
    private var connectionTimer: some View {
        if let since = tracker.parkedSince {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let secs = max(0, Int(ctx.date.timeIntervalSince(since)))
                let isConn = Connection.isConnection(secs)
                Label(isConn ? "Connection · \(Connection.label(secs))"
                             : "Stopped \(Connection.label(secs)) · saves as separate trips",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isConn ? Color.purple : Color.orange)
                    .contentTransition(.numericText())
            }
        }
    }

    /// "Divert" — change where you're headed after the drive has started: pick another destination,
    /// or drop the destination and just keep tracking.
    private func divertMenu(compact: Bool) -> some View {
        Menu {
            Button { showingDivertSearch = true } label: {
                Label("Choose New Destination…", systemImage: "mappin.and.ellipse")
            }
            Button(role: .destructive) { Haptics.tap(); divert(to: nil) } label: {
                Label("No Destination (Just Track)", systemImage: "location.slash")
            }
        } label: {
            Label("Divert", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity).padding(.vertical, compact ? 12 : 13)
                .background(Color(.systemGray6), in: .capsule)
        }
    }

    private func divert(to stop: RouteStop?) {
        withAnimation(.spring(duration: 0.3)) { tracker.divert(to: stop) }
        guide.clear()
        guide.invalidate()
        guide.refresh(tracker: tracker)
        activeDrive.pushLiveUpdate()
    }

    private func vehicleChip(_ vehicle: Vehicle) -> some View {
        Button { showingVehiclePicker = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "car.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vehicle.name).font(.subheadline).fontWeight(.medium)
                    if let mpg = vehicle.avgMpg {
                        Text(String(format: "%.0f MPG", mpg)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var startButton: some View {
        Button {
            Haptics.rigid()
            withAnimation(.spring(duration: 0.4)) { startTracking() }
        } label: {
            controlLabel("Start Tracking", "location.fill", .green)
        }
        .disabled(tracker.authorizationStatus == .denied || tracker.authorizationStatus == .restricted)
    }

    private var stopButton: some View {
        Button {
            Haptics.rigid()
            endDrive()
        } label: {
            // "End Drive" for a routed (destination/multi-leg) drive; plain "Stop" for an open drive.
            controlLabel(!tracker.hasActiveTarget ? "Stop" : "End Drive", "stop.fill", .red)
        }
    }

    /// Pre-start destination picker for an ad-hoc drive. Setting one gives the drive a live ETA and
    /// routes toward it, just like a "Go to" — the way to put a destination on a non-scheduled route.
    private var destinationRow: some View {
        Button { Haptics.tap(); showingAddStop = true } label: {
            HStack(spacing: 12) {
                Image(systemName: tracker.destination == nil ? "mappin.and.ellipse" : "mappin.circle.fill")
                    .foregroundStyle(.blue).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tracker.destination == nil ? "Set destination" : (tracker.destinationName ?? "Destination"))
                        .font(.subheadline).fontWeight(.medium).lineLimit(1)
                    Text(tracker.destination == nil ? "Optional — adds a live ETA" : "Tap to change")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// While driving an open / single-destination drive: add a stop (or set the first destination)
    /// on the fly. The route becomes a linked multi-stop journey the moment a stop is added.
    private var addStopButton: some View {
        Button { Haptics.tap(); showingAddStop = true } label: {
            Label(!tracker.hasActiveTarget ? "Set destination" : "Add a stop",
                  systemImage: !tracker.hasActiveTarget ? "mappin.and.ellipse" : "plus.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Color(.systemGray6), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    /// Sheet title reflects whether we're setting the first destination or adding a later stop.
    private var addStopSheetTitle: String { !tracker.hasActiveTarget ? "Set Destination" : "Add Stop" }

    /// Compact duration for a single leg's recap ("8m 12s" / "1h 4m").
    private func legDurationString(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func controlLabel(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3)
            Text(text).font(.title3).fontWeight(.semibold)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(color.gradient, in: .capsule)
        .shadow(color: color.opacity(0.4), radius: 12, y: 4)
    }

    // MARK: - Actions

    private func startTracking() {
        tracker.plannedVehicleName = selectedVehicle?.name
        tracker.ratedMpg = selectedVehicle?.avgMpg
        tracker.startTracking()
        followUser = true
        cameraPosition = followCameraPosition()
        guide.clear()
        guide.invalidate()
        guide.refresh(tracker: tracker)
        activeDrive.startLiveActivity()
        activeDrive.broadcastLive()
    }

    /// Continue an interrupted drive: rebuild the tracker from the crash log and pick up recording
    /// (or the paused-between-legs state) exactly where it left off.
    private func resumeRecovered(_ rec: DriveLogger.Recovered) {
        selectedVehicle = vehicles.first(where: { $0.name == rec.meta.vehicleName }) ?? selectedVehicle
        tracker.ratedMpg = selectedVehicle?.avgMpg
        tracker.resume(from: rec)
        recovered = nil
        followUser = true
        cameraPosition = followCameraPosition()
        guide.clear()
        guide.invalidate()
        guide.refresh(tracker: tracker)
        activeDrive.startLiveActivity()
        activeDrive.broadcastLive()
    }

    // Live Activity start/update/end + Watch live-broadcast all live on `ActiveDriveController` now
    // (see its doc comment) so they keep running whether this view is shown full-screen or minimized.

    private func saveTrip(category: TripCategory, paidBy: String, notes: String?) {
        let pts = tracker.points
        let scheduledDeparture = tracker.scheduledDeparture
        let scheduledArrival = tracker.scheduledArrival
        let tripName = tracker.tripName
        let schedStart = scheduled?.startAddress
        let vehName = selectedVehicle?.name
        let vehMpg = selectedVehicle?.avgMpg
        let legTargets = tracker.legTargets
        let boundaries = tracker.legPointBoundaries
        let divertedFrom = tracker.divertedFromName
        let divertLeg = tracker.divertLegIndex
        // A simple A→B drive always adopts its destination name; a multi-leg drive that ends early —
        // parked at the last stop, or miles short of the endpoint — reverse-geocodes where it
        // actually stopped instead of claiming the final destination.
        let reachedFinal: Bool
        if tracker.isMultiLeg {
            reachedFinal = tracker.isOnFinalLeg && !tracker.isPausedBetweenLegs
                && (tracker.legRemainingMiles ?? .infinity) < 0.25
        } else {
            // A diverted-to-nowhere drive has no destination to claim — name where it really ended.
            reachedFinal = tracker.hasActiveTarget
        }
        let finalName = tracker.finalDestinationName ?? tracker.destinationName
        // Dismiss + clear the crash log *synchronously* so the trip can't be saved twice (a second
        // Save tap during the async save, or a stale crash-recovery) creating a duplicate.
        tracker.clearCrashLog()
        showingSummary = false
        // The scheduled occurrence is done — drop it off the departures board.
        scheduled?.lastCompletedAt = .now
        try? context.save()
        guard pts.first?.coordinate != nil, pts.last?.coordinate != nil else {
            finishAndExit()
            return
        }
        // Split the recording into legs at the stop boundaries. A multi-stop drive becomes several
        // separate, linked trips (one per leg); a single-leg drive stays one standalone trip.
        Task { @MainActor in
            let inputs = await buildLegInputs(
                pts: pts, legTargets: legTargets, boundaries: boundaries,
                firstLegStart: schedStart, reachedFinal: reachedFinal, finalName: finalName,
                category: category, paidBy: paidBy, notes: notes, tripName: tripName,
                vehName: vehName, vehMpg: vehMpg,
                scheduledDeparture: scheduledDeparture, scheduledArrival: scheduledArrival,
                divertedFrom: divertedFrom, divertLegIndex: divertLeg)
            await saveInputs(inputs)
        }
        finishAndExit()
    }

    /// Persist the split result: >1 leg → a linked journey; exactly 1 → a standalone trip; 0 → the
    /// drive had no leg with ≥2 points (not a recordable trip), so nothing is saved.
    @MainActor
    private func saveInputs(_ inputs: [TripStore.Input]) async {
        // A stop shorter than `Connection.maxLayover` is a *connection* inside one journey; a longer
        // one ends the trip, so the legs on either side are saved as separate groups.
        var groups: [[TripStore.Input]] = []
        for input in inputs {
            if !groups.isEmpty, Connection.isConnection(input.layoverSeconds) {
                groups[groups.count - 1].append(input)
            } else {
                var first = input
                first.layoverSeconds = 0
                groups.append([first])
            }
        }
        for group in groups {
            if group.count == 1 {
                await TripStore.save(group[0], context: context)
            } else {
                await TripStore.saveJourney(group, context: context)
            }
        }
    }

    /// Segment a finished recording into one `TripStore.Input` per leg. Endpoint names are resolved
    /// by POSITION (reached-stop names, reverse-geocoding where a name is missing) so filtering out a
    /// degenerate <2-point leg can never misname the survivors; the journey-level schedule + notes
    /// are then pinned to the SURVIVING first/last legs (never stranded on a dropped leg).
    private func buildLegInputs(
        pts: [RecordedPoint], legTargets: [RouteStop], boundaries: [Int],
        firstLegStart: String?, reachedFinal: Bool, finalName: String?,
        category: TripCategory, paidBy: String, notes: String?, tripName: String?,
        vehName: String?, vehMpg: Double?,
        scheduledDeparture: Date?, scheduledArrival: Date?,
        divertedFrom: String? = nil, divertLegIndex: Int = 0
    ) async -> [TripStore.Input] {
        struct Seg { let legIndex: Int; let lo: Int; let hi: Int; let fromName: String?; let toName: String? }
        func stopName(_ idx: Int) -> String? {
            guard legTargets.indices.contains(idx) else { return nil }
            let a = legTargets[idx].address
            return a.isEmpty ? nil : a
        }
        // 1. Build a segment per leg with its endpoint names (nil = reverse-geocode the real point).
        var segs: [Seg] = []
        var prev = 0
        for (i, b) in boundaries.enumerated() where b > prev && b <= pts.count {
            segs.append(Seg(legIndex: i, lo: prev, hi: b, fromName: i == 0 ? firstLegStart : stopName(i - 1), toName: stopName(i)))
            prev = b
        }
        if pts.count - prev >= 1 {  // final leg toward the destination (kept below only if ≥2 points)
            let i = boundaries.count
            let from = boundaries.isEmpty ? firstLegStart : stopName(boundaries.count - 1)
            segs.append(Seg(legIndex: i, lo: prev, hi: pts.count, fromName: from, toName: reachedFinal ? finalName : nil))
        }
        // 2. Keep only legs long enough to form a trip.
        let valid = segs.filter { $0.hi - $0.lo >= 2 }
        guard !valid.isEmpty else { return [] }

        // 3. Compute scheduled departure/arrival for each logical leg if we have per-leg times.
        // `legTargets` already INCLUDES the final destination as its last element (`setRoute`
        // appends it), so there are exactly `legTargets.count` legs, indexed `0..<legTargets.count`
        // — the segment-building above assigns the final leg exactly this `legIndex`
        // (`boundaries.count`, which equals `legTargets.count - 1` once every intermediate stop's
        // been reached). This used to loop `0...legTargets.count` and only read `baseArr` on
        // `i == legTargets.count` — one past the last real leg, so it was NEVER assigned to any
        // actual segment. Every leg, including the final one, instead fell into the `i <
        // legTargets.count` branch and computed its arrival from `legTargets[i].legDriveSeconds` —
        // which is 0 for the final destination's appended `RouteStop` (only intermediate stops ever
        // get a `legDriveSeconds`), so the final leg's scheduled arrival collapsed to equal its own
        // departure. Every multi-stop scheduled drive's LAST leg (the one that actually reaches the
        // destination) was graded against a zero-length budget — reading wildly DELAYED even when
        // driven exactly on schedule — and skewed `DrivingStats.totalDelaySeconds`/`onTimeCount`.
        var logicalSchedules: [Int: (dep: Date, arr: Date)] = [:]
        let hasLegTimes = legTargets.isEmpty || legTargets.contains { $0.legDriveSeconds > 0 }
        if hasLegTimes, let baseDep = scheduledDeparture, let baseArr = scheduledArrival {
            let legCount = max(legTargets.count, 1)
            var currentDep = baseDep
            for i in 0..<legCount {
                let dep = currentDep
                let arr: Date
                if i == legCount - 1 {
                    arr = baseArr  // the last leg lands on the schedule's own overall arrival
                } else {
                    let stop = legTargets[i]
                    arr = dep.addingTimeInterval(TimeInterval(stop.legDriveSeconds))
                    currentDep = arr.addingTimeInterval(TimeInterval(stop.dwellMinutes * 60))
                }
                logicalSchedules[i] = (dep, arr)
            }
        }

        // 4. Build the inputs, reverse-geocoding any endpoint with no known name.
        var inputs: [TripStore.Input] = []
        var prevLastTime: Date?
        for seg in valid {
            let legPts = Array(pts[seg.lo..<seg.hi])
            guard let first = legPts.first, let last = legPts.last else { continue }
            let startAddr: String
            if let n = seg.fromName { startAddr = n } else { startAddr = await reverseGeocode(first.coordinate) }
            let endAddr: String
            if let n = seg.toName { endAddr = n } else { endAddr = await reverseGeocode(last.coordinate) }
            
            var input = TripStore.Input(
                points: legPts, startAddress: startAddr, endAddress: endAddr,
                category: category, paidBy: paidBy, notes: nil, name: tripName,
                vehicleName: vehName, vehicleMpg: vehMpg)
            
            if let sched = logicalSchedules[seg.legIndex] {
                input.scheduledDeparture = sched.dep
                input.scheduledArrival = sched.arr
            }
            // Connection time = parked gap since the previous surviving leg's last fix.
            if let prevLast = prevLastTime {
                input.layoverSeconds = max(0, Int(first.t.timeIntervalSince(prevLast)))
            }
            prevLastTime = last.t
            inputs.append(input)
        }
        // Mark the leg during which the driver changed course (else the last one).
        if let divertedFrom, !inputs.isEmpty {
            let idx = valid.firstIndex(where: { $0.legIndex == divertLegIndex }) ?? inputs.count - 1
            inputs[min(idx, inputs.count - 1)].divertedFromName = divertedFrom
        }

        // 5. Pin journey-level notes to the first leg, and handle legacy schedules.
        if !inputs.isEmpty {
            inputs[0].notes = notes
            if !hasLegTimes {
                inputs[0].scheduledDeparture = scheduledDeparture
                inputs[inputs.count - 1].scheduledArrival = scheduledArrival
            }
        }
        return inputs
    }

    private func discardTrip() {
        tracker.clearCrashLog()
        showingSummary = false
        // A discarded scheduled drive is still *over* — record completion so its occurrence drops
        // off the departures board, exactly like Save does. Without this the drive stays stuck
        // showing DEPARTED (lastStartedAt was set at launch, but nothing recorded the finish).
        scheduled?.lastCompletedAt = .now
        try? context.save()
        finishAndExit()
    }

    /// Leave a finished drive cleanly: a modal (scheduled) drive dismisses back to its detail page;
    /// a Track-tab drive resets the tracker and routes to the Dashboard, so the user never sees the
    /// old trip's stale stats flash by on the way out.
    private func finishAndExit() {
        guide.clear()
        guide.invalidate()
        activeDrive.endLiveBroadcast()
        activeDrive.endLiveActivity()
        if isModal {
            dismiss()
        } else {
            tracker.resetAfterFinish()
            onFinish?()
        }
    }

    /// Synchronous entry point for the recovery banner's Save button: hide the banner and clear the
    /// on-disk log *before* any await so a double-tap can't save (and sync) the drive twice. The
    /// recovered points/meta live in `rec` (memory), so saving still works after the log is cleared.
    private func startSaveRecovered(_ rec: DriveLogger.Recovered) {
        guard recovered != nil else { return }
        recovered = nil
        LocationTracker.discardRecoverableSession()
        // Same as the trash button: this session's Live Activity (if any) belongs to a previous,
        // now-dead process — this one never called `start()` for it, so nothing else will end it.
        #if canImport(ActivityKit) && !os(macOS)
        Task { await LiveActivityController.endOrphaned() }
        #endif
        Task { await saveRecovered(rec) }
    }

    private func saveRecovered(_ rec: DriveLogger.Recovered) async {
        let veh = vehicles.first(where: { $0.name == rec.meta.vehicleName })
        let pts = rec.points
        guard pts.count >= 2 else { return }
        let meta = rec.meta
        let category = TripCategory(rawValue: meta.category) ?? .other
        let paidBy = meta.paidBy
        // Split a recovered multi-stop drive into per-leg linked trips too (an interrupted final leg
        // reverse-geocodes where it actually stopped rather than claiming an unreached target).
        let inputs = await buildLegInputs(
            pts: pts, legTargets: meta.legTargets, boundaries: meta.legPointBoundaries,
            firstLegStart: nil, reachedFinal: false, finalName: nil,
            category: category, paidBy: paidBy, notes: "Recovered drive", tripName: meta.tripName,
            vehName: meta.vehicleName, vehMpg: veh?.avgMpg,
            scheduledDeparture: meta.scheduledDeparture, scheduledArrival: meta.scheduledArrival,
            divertedFrom: meta.divertedFromName, divertLegIndex: meta.divertLegIndex)
        await saveInputs(inputs)
    }

    private func stopIfNeededAndDismiss() {
        if tracker.isTracking {
            tracker.stopTracking()
            presentSummaryOrAutoSave()
        } else {
            dismiss()
        }
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String {
        let fallback = String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return fallback }
        if let items = try? await request.mapItems, let name = items.first?.name, !name.isEmpty {
            return name
        }
        return fallback
    }
}

/// Grows a thinned copy of the recorded track as fixes arrive. Rebuilding `points.map(\.coordinate)` for
/// thousands of fixes on every redraw (about once a second) made the live map heavier the longer a
/// drive ran; this only touches the new points. Reference type on purpose: mutating it during `body`
/// must not invalidate the view.
final class TrailCache {
    private var coords: [CLLocationCoordinate2D] = []
    private var consumed = 0

    func coordinates(for points: [RecordedPoint]) -> [CLLocationCoordinate2D] {
        if points.count < consumed { coords = []; consumed = 0 }   // a new drive
        guard points.count > consumed else { return coords }
        for p in points[consumed...] {
            if let last = coords.last, p.coordinate.distanceMeters(to: last) < 4 { continue }
            coords.append(p.coordinate)
        }
        // Always end exactly on the newest fix so the line reaches the car.
        if let newest = points.last?.coordinate, let last = coords.last,
           last.latitude != newest.latitude || last.longitude != newest.longitude {
            coords.append(newest)
        }
        consumed = points.count
        return coords
    }
}

// MARK: - Vehicle Picker Sheet

struct VehiclePickerSheet: View {
    let vehicles: [Vehicle]
    @Binding var selected: Vehicle?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vehicles.isEmpty {
                    ContentUnavailableView("No Vehicles", systemImage: "car.fill",
                                           description: Text("Add a vehicle in Settings first"))
                } else {
                    ForEach(vehicles) { vehicle in
                        Button {
                            selected = vehicle
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vehicle.name).font(.headline)
                                    Text(vehicleSubtitle(vehicle)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == vehicle.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Select Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func vehicleSubtitle(_ v: Vehicle) -> String {
        var parts: [String] = []
        if let y = v.year { parts.append(String(y)) }
        if let m = v.make { parts.append(m) }
        if let mo = v.model { parts.append(mo) }
        if let mpg = v.avgMpg { parts.append(String(format: "%.0f MPG", mpg)) }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }
}
