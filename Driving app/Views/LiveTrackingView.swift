import SwiftUI
import MapKit
import SwiftData

struct LiveTrackingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var vehicles: [Vehicle]

    /// When launched from a scheduled drive, the view runs modally and pre-loads the destination.
    let scheduled: ScheduledDrive?

    /// Presented as a full-screen cover from the Drive tab (ad-hoc "Start a Drive"). Adds a close
    /// button and dismisses on finish, exactly like a scheduled modal drive.
    let asModal: Bool

    /// Called after the cover is dismissed (saved or discarded) so the presenter can tear it down.
    var onFinish: (() -> Void)?

    @State private var tracker: LocationTracker
    @State private var selectedVehicle: Vehicle?
    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var followUser = true
    @State private var showingSummary = false
    @State private var showingVehiclePicker = false
    @State private var showingAddStop = false
    @State private var recovered: DriveLogger.Recovered?
    @State private var didAutoStart = false

    /// The most-efficient (fastest) road route from where the driver is now to the destination,
    /// drawn as a dotted light-blue guide line. Refreshed as they drive so it re-routes if they
    /// deviate. Empty when there's no destination or no route yet.
    @State private var efficientRoute: [CLLocationCoordinate2D] = []
    @State private var lastRouteFetchFrom: CLLocationCoordinate2D?

    init(scheduled: ScheduledDrive? = nil, asModal: Bool = false, onFinish: (() -> Void)? = nil) {
        self.scheduled = scheduled
        self.asModal = asModal
        self.onFinish = onFinish
        _tracker = State(initialValue: LocationTracker())
    }

    #if DEBUG
    init(previewTracker: LocationTracker) {
        self.scheduled = nil
        self.asModal = false
        self.onFinish = nil
        _tracker = State(initialValue: previewTracker)
    }
    #endif

    private var isModal: Bool { scheduled != nil || asModal }

    private var navTitle: String {
        if tracker.isTracking { return "Tracking" }
        if isModal { return scheduled?.title ?? "Drive" }
        return "Track Drive"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapLayer

                VStack(spacing: 12) {
                    if let recovered, !tracker.isTracking {
                        recoveryBanner(recovered)
                    }
                    if tracker.isTracking {
                        if tracker.isMultiLeg {
                            legProgressStrip
                        }
                        statsHUD
                        secondaryHUD
                        if tracker.destination != nil, !tracker.isPausedBetweenLegs {
                            etaHUD
                        }
                    }
                    Spacer()
                    bottomControls
                }
                .padding()

                recenterButton
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isModal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { stopIfNeededAndDismiss() } label: { Image(systemName: "xmark") }
                    }
                }
            }
            .onAppear(perform: setup)
            // Bring CoreLocation up off the first-render path so the tab appears instantly the
            // first time; the map's user dot fills in a moment later.
            .task { tracker.activateIdle() }
            // Wrist controls: only the instance that's actually tracking acts on them.
            .onReceive(NotificationCenter.default.publisher(for: .endDriveFromWatch)) { _ in
                guard tracker.isTracking else { return }
                endDrive()
            }
            .onReceive(NotificationCenter.default.publisher(for: .arriveStopFromWatch)) { _ in
                guard tracker.isTracking, tracker.isMultiLeg, !tracker.isOnFinalLeg, !tracker.isPausedBetweenLegs else { return }
                withAnimation(.spring(duration: 0.4)) { tracker.arriveAtCurrentStop() }
                lastRouteFetchFrom = nil
                refreshEfficientRoute()
                updateLiveActivity()
            }
            .onReceive(NotificationCenter.default.publisher(for: .startNextLegFromWatch)) { _ in
                guard tracker.isTracking, tracker.isPausedBetweenLegs else { return }
                withAnimation(.spring(duration: 0.4)) { tracker.startNextLeg() }
                followUser = true
                lastRouteFetchFrom = nil
                refreshEfficientRoute()
                updateLiveActivity()
            }
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
                LocationSearchSheet(title: "Add Stop") { picked in
                    Haptics.tap()
                    tracker.appendLiveStop(RouteStop(address: picked.address, coordinate: picked.coordinate))
                    lastRouteFetchFrom = nil  // force the guide line to re-route to the new next stop
                    refreshEfficientRoute()
                    updateLiveActivity()
                }
            }
        }
    }

    // MARK: - Setup / scheduled start

    private func setup() {
        // Permission + location startup happen in `.task` (activateIdle) to keep first render cheap.
        if selectedVehicle == nil {
            selectedVehicle = vehicles.first(where: { $0.name == scheduled?.vehicleName }) ?? vehicles.first
        }
        // A scheduled drive starts a fresh session; an ad-hoc drive (Track/Start a Drive) offers to
        // recover any interrupted session first.
        if scheduled == nil {
            recovered = LocationTracker.recoverableSession()
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
            tracker.plannedPaidBy = scheduled.paidBy
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

            // Dotted light-blue guide: the most efficient route still ahead to the destination.
            // Drawn first so the actual (solid) track sits on top of it.
            if tracker.isTracking, efficientRoute.count >= 2 {
                MapPolyline(coordinates: efficientRoute)
                    .stroke(.cyan.opacity(0.9),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [1, 12]))
            }

            if tracker.points.count >= 2 {
                MapPolyline(coordinates: tracker.points.map(\.coordinate))
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
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
                if i < tracker.legTargets.count - 1 {
                    Annotation(target.address.isEmpty ? "Stop \(i + 1)" : target.address,
                               coordinate: target.coordinate) {
                        legStopPin(index: i)
                    }
                }
            }
            if let dest = tracker.legTargets.last?.coordinate ?? tracker.destination {
                Annotation(tracker.finalDestinationName ?? tracker.destinationName ?? "Destination", coordinate: dest) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
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
        // follow camera, guide-route refresh, and Live Activity.
        .onChange(of: tracker.fixCount) { _, _ in
            if followUser, let loc = tracker.currentLocation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: loc,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
            }
            refreshEfficientRoute()
            updateLiveActivity()
        }
        // Keep the Live Activity's clock/ETA advancing even while parked (no new fixes); the
        // controller throttles, so a per-second tick collapses to a push every few seconds.
        .onChange(of: tracker.elapsedSeconds) { _, _ in updateLiveActivity() }
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
    /// control that sat in the top corner underneath the time).
    private var recenterButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    followUser = true
                    if let loc = tracker.currentLocation {
                        withAnimation { cameraPosition = .region(MKCoordinateRegion(
                            center: loc, span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))) }
                    } else {
                        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .padding(12)
                        .background(.ultraThinMaterial, in: .circle)
                        .shadow(radius: 4, y: 2)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 160)
            }
        }
    }

    // MARK: - Stats HUD

    private var statsHUD: some View {
        HStack(spacing: 0) {
            statItem(value: String(format: "%.1f", tracker.distanceMiles), unit: "mi",
                     icon: "point.topleft.down.to.point.bottomright.curvepath.fill")
            Divider().frame(height: 40)
            statItem(value: tracker.formattedElapsed(), unit: "time", icon: "clock.fill")
            Divider().frame(height: 40)
            statItem(value: String(format: "%.0f", tracker.currentSpeed), unit: "mph", icon: "speedometer")
        }
        .padding(.vertical, 12).padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.move(edge: .top).combined(with: .opacity))
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

    // A second, slimmer row of live data for richer at-a-glance telemetry.
    private var secondaryHUD: some View {
        HStack(spacing: 0) {
            miniStat(String(format: "%.0f", tracker.avgSpeedMph), "avg mph")
            Divider().frame(height: 26)
            miniStat(String(format: "%.0f", tracker.maxSpeed), "max mph")
            Divider().frame(height: 26)
            miniStat(movingTimeString, "moving")
            if let mpg = selectedVehicle?.avgMpg, mpg > 0 {
                Divider().frame(height: 26)
                miniStat(String(format: "%.2f", tracker.accumulatedGallons), "gal")
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func miniStat(_ value: String, _ unit: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold)).fontDesign(.rounded)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var movingTimeString: String {
        let s = tracker.movingSeconds
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    // MARK: - ETA / delay HUD

    private var etaHUD: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.isMultiLeg ? "ETA (final)" : "ETA").font(.caption2).foregroundStyle(.secondary)
                if let eta = tracker.etaDate {
                    Text(eta, format: .dateTime.hour().minute())
                        .font(.headline).fontDesign(.rounded)
                } else {
                    Text("—").font(.headline)
                }
                if let dest = tracker.finalDestinationName ?? tracker.destinationName {
                    Text(dest).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let scheduled = tracker.scheduledArrival {
                VStack(alignment: .center, spacing: 2) {
                    Text("Scheduled").font(.caption2).foregroundStyle(.secondary)
                    Text(scheduled, format: .dateTime.hour().minute())
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
            }
            if tracker.scheduledArrival != nil {
                StatusChip(status: .live(delaySeconds: tracker.delaySeconds))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.move(edge: .top).combined(with: .opacity))
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
            Button { LocationTracker.discardRecoverableSession(); recovered = nil } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
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
                        endDriveButton(prominent: false)
                    } else {
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
    }

    /// Shown while parked between legs: which stop you reached, and the button to head to the next.
    private var pausedControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "parkingsign.circle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    let reached = tracker.reachedStopCount
                    Text("Stopped at Stop \(reached)").font(.subheadline.weight(.semibold))
                    if let next = tracker.currentLegTarget {
                        Text("Next: \(next.address.isEmpty ? "Destination" : next.address)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))

            Button {
                Haptics.rigid()
                withAnimation(.spring(duration: 0.4)) { tracker.startNextLeg() }
                followUser = true
                lastRouteFetchFrom = nil
                refreshEfficientRoute()
                updateLiveActivity()
            } label: {
                controlLabel(tracker.isOnFinalLeg ? "Drive to Destination" : "Start Next Leg", "location.fill", .blue)
            }

            HStack(spacing: 10) {
                Button { Haptics.tap(); showingAddStop = true } label: {
                    Label("Add stop", systemImage: "plus")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.systemGray6), in: .capsule)
                }
                Button { Haptics.rigid(); endDrive() } label: {
                    Label("End drive", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
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
            // The target advanced to the next stop — re-route the dotted guide line to it.
            lastRouteFetchFrom = nil
            refreshEfficientRoute()
            updateLiveActivity()
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

    /// End the whole drive now (from any leg) → summary.
    private func endDrive() {
        withAnimation(.spring(duration: 0.4)) { tracker.stopTracking() }
        showingSummary = true
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
            controlLabel(tracker.legTargets.isEmpty ? "Stop" : "End Drive", "stop.fill", .red)
        }
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
        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
        efficientRoute = []
        lastRouteFetchFrom = nil
        refreshEfficientRoute()
        startLiveActivity()
        broadcastLive()
    }

    /// Continue an interrupted drive: rebuild the tracker from the crash log and pick up recording
    /// (or the paused-between-legs state) exactly where it left off.
    private func resumeRecovered(_ rec: DriveLogger.Recovered) {
        selectedVehicle = vehicles.first(where: { $0.name == rec.meta.vehicleName }) ?? selectedVehicle
        tracker.ratedMpg = selectedVehicle?.avgMpg
        tracker.resume(from: rec)
        recovered = nil
        followUser = true
        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
        efficientRoute = []
        lastRouteFetchFrom = nil
        refreshEfficientRoute()
        startLiveActivity()
        broadcastLive()
    }

    // MARK: - Live Activity (trip progress on Lock Screen / Dynamic Island)

    private func startLiveActivity() {
        #if canImport(ActivityKit) && !os(macOS)
        LiveActivityController.start(title: tracker.tripName ?? "Drive",
                                     scheduledArrival: tracker.scheduledArrival,
                                     state: liveActivityState())
        #endif
    }

    private func updateLiveActivity() {
        #if canImport(ActivityKit) && !os(macOS)
        guard tracker.isTracking else { return }
        LiveActivityController.update(liveActivityState())
        #endif
        broadcastLive()
    }

    /// Stream the current drive to the Apple Watch so it can be the live focus.
    private func broadcastLive() {
        #if canImport(WatchConnectivity) && os(iOS)
        guard tracker.isTracking else { return }
        var progress: Double?
        if let remaining = tracker.remainingMiles {
            let done = tracker.distanceMiles
            let total = done + max(remaining, 0)
            progress = total > 0.1 ? min(1, done / total) : nil
        }
        var legText: String?
        if tracker.isMultiLeg {
            var t = "Leg \(min(tracker.currentLegIndex + 1, tracker.totalLegs)) of \(tracker.totalLegs)"
            if let next = tracker.currentLegTarget, !next.address.isEmpty { t += " · \(next.address)" }
            legText = t
        }
        let live = WatchSyncPayload.Live(
            tripName: tracker.tripName ?? tracker.finalDestinationName ?? "Drive",
            milesTraveled: tracker.distanceMiles,
            currentSpeed: tracker.currentSpeed,
            elapsedSeconds: tracker.elapsedSeconds,
            eta: tracker.etaDate,
            delaySeconds: tracker.delaySeconds,
            progress: progress,
            legText: legText,
            isPaused: tracker.isPausedBetweenLegs,
            canAdvanceLeg: tracker.isMultiLeg && !tracker.isOnFinalLeg && !tracker.isPausedBetweenLegs)
        PhoneWatchConnectivity.shared.sendLive(live)
        #endif
    }

    private func endLiveBroadcast() {
        #if canImport(WatchConnectivity) && os(iOS)
        PhoneWatchConnectivity.shared.sendLive(nil)
        #endif
    }

    #if canImport(ActivityKit) && !os(macOS)
    private func liveActivityState() -> DriveActivityAttributes.ContentState {
        // Progress toward the destination = traveled / (traveled + straight-line remaining).
        var progress: Double?
        if let remaining = tracker.remainingMiles {
            let done = tracker.distanceMiles
            let total = done + max(remaining, 0)
            progress = total > 0.1 ? min(1, done / total) : nil
        }
        // Show the overall destination; for a multi-leg drive, append the current leg (e.g. "Home
        // · Stop 2 of 3") so the Lock Screen reflects the leg you're on.
        var name = tracker.finalDestinationName ?? tracker.destinationName
        if tracker.isMultiLeg, let base = name {
            name = "\(base) · Stop \(min(tracker.currentLegIndex + 1, tracker.totalLegs))/\(tracker.totalLegs)"
        }
        return .init(milesTraveled: tracker.distanceMiles,
                     currentSpeed: tracker.currentSpeed,
                     elapsedSeconds: tracker.elapsedSeconds,
                     progress: progress,
                     eta: tracker.etaDate,
                     delaySeconds: tracker.delaySeconds,
                     destinationName: name)
    }
    #endif

    /// Fetch the fastest road route from the current location to the destination for the dotted
    /// guide line. Throttled: only re-routes after the driver has moved ~350 m (or when we have no
    /// line yet), keeping well under MapKit's directions rate limit while still re-routing on
    /// meaningful deviations.
    private func refreshEfficientRoute() {
        guard tracker.isTracking, let dest = tracker.destination, let from = tracker.currentLocation else { return }
        if let last = lastRouteFetchFrom, !efficientRoute.isEmpty, from.distanceMeters(to: last) < 350 { return }
        lastRouteFetchFrom = from
        Task {
            let routes = await RouteMatcher.candidateRoutes(from: from, to: dest)
            guard let best = routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { return }
            let coords = best.polyline.coordinates()
            await MainActor.run {
                // Ignore a stale response if the drive ended while it was in flight.
                if tracker.isTracking { efficientRoute = coords }
            }
        }
    }

    private func saveTrip(category: TripCategory, paidBy: PaidBy, notes: String?) {
        let pts = tracker.points
        let scheduledDeparture = tracker.scheduledDeparture
        let scheduledArrival = tracker.scheduledArrival
        let tripName = tracker.tripName
        let schedStart = scheduled?.startAddress
        let vehName = selectedVehicle?.name
        let vehMpg = selectedVehicle?.avgMpg
        // Record only the intermediate stops actually reached (a drive ended early keeps just the
        // stops it passed). Label the endpoint with the destination's name only when it was really
        // reached: a simple A→B drive always adopts its destination name (unchanged behavior), but a
        // multi-leg drive that ends early — parked at the last stop, or miles short of the endpoint —
        // must reverse-geocode where it actually stopped instead of claiming the final destination.
        let stops = Array(tracker.legTargets.prefix(tracker.reachedStopCount))
        let reachedFinal: Bool
        if tracker.isMultiLeg {
            reachedFinal = tracker.isOnFinalLeg && !tracker.isPausedBetweenLegs
                && (tracker.legRemainingMiles ?? .infinity) < 0.25
        } else {
            reachedFinal = true
        }
        let finalName = tracker.finalDestinationName ?? tracker.destinationName
        // Dismiss + clear the crash log *synchronously* so the trip can't be saved twice (a second
        // Save tap during the async save, or a stale crash-recovery) creating a duplicate.
        tracker.clearCrashLog()
        showingSummary = false
        // The scheduled occurrence is done — drop it off the departures board.
        scheduled?.lastCompletedAt = .now
        try? context.save()
        guard let start = pts.first?.coordinate, let end = pts.last?.coordinate else {
            finishAndExit()
            return
        }
        Task { @MainActor in
            let startAddr: String
            if let schedStart { startAddr = schedStart } else { startAddr = await reverseGeocode(start) }
            let endAddr: String
            if reachedFinal, let finalName { endAddr = finalName } else { endAddr = await reverseGeocode(end) }
            let input = TripStore.Input(
                points: pts, startAddress: startAddr, endAddress: endAddr,
                category: category, paidBy: paidBy, notes: notes, name: tripName,
                vehicleName: vehName, vehicleMpg: vehMpg,
                scheduledDeparture: scheduledDeparture, scheduledArrival: scheduledArrival,
                stops: stops
            )
            await TripStore.save(input, context: context)
        }
        finishAndExit()
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
        efficientRoute = []
        lastRouteFetchFrom = nil
        endLiveBroadcast()
        #if canImport(ActivityKit) && !os(macOS)
        LiveActivityController.end()
        #endif
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
        Task { await saveRecovered(rec) }
    }

    private func saveRecovered(_ rec: DriveLogger.Recovered) async {
        let veh = vehicles.first(where: { $0.name == rec.meta.vehicleName })
        guard let start = rec.points.first?.coordinate, let end = rec.points.last?.coordinate else { return }
        let startAddr = await reverseGeocode(start)
        // An interrupted drive almost never reached its destination, so label the endpoint by the
        // actual last recorded point rather than a leg target it may not have reached.
        let endAddr = await reverseGeocode(end)
        // Keep the intermediate stops the recovered drive had already reached.
        let reached = min(rec.meta.currentLegIndex, max(rec.meta.legTargets.count - 1, 0))
        let stops = Array(rec.meta.legTargets.prefix(reached))
        let input = TripStore.Input(
            points: rec.points, startAddress: startAddr, endAddress: endAddr,
            category: TripCategory(rawValue: rec.meta.category) ?? .other,
            paidBy: PaidBy(rawValue: rec.meta.paidBy) ?? .myself,
            notes: "Recovered drive", name: rec.meta.tripName,
            vehicleName: rec.meta.vehicleName, vehicleMpg: veh?.avgMpg,
            scheduledDeparture: rec.meta.scheduledDeparture, scheduledArrival: rec.meta.scheduledArrival,
            stops: stops
        )
        await TripStore.save(input, context: context)
    }

    private func stopIfNeededAndDismiss() {
        if tracker.isTracking {
            tracker.stopTracking()
            showingSummary = true
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
