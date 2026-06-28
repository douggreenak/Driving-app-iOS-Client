import SwiftUI
import MapKit
import SwiftData

struct LiveTrackingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var vehicles: [Vehicle]

    /// When launched from a scheduled drive, the view runs modally and pre-loads the destination.
    let scheduled: ScheduledDrive?

    @State private var tracker: LocationTracker
    @State private var selectedVehicle: Vehicle?
    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var followUser = true
    @State private var showingSummary = false
    @State private var showingVehiclePicker = false
    @State private var recovered: DriveLogger.Recovered?
    @State private var didAutoStart = false

    init(scheduled: ScheduledDrive? = nil) {
        self.scheduled = scheduled
        _tracker = State(initialValue: LocationTracker())
    }

    #if DEBUG
    init(previewTracker: LocationTracker) {
        self.scheduled = nil
        _tracker = State(initialValue: previewTracker)
    }
    #endif

    private var isModal: Bool { scheduled != nil }

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
                        statsHUD
                        secondaryHUD
                        if tracker.destination != nil {
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
            .sheet(isPresented: $showingSummary) {
                TripSummaryView(tracker: tracker, vehicle: selectedVehicle,
                                initialPaidBy: tracker.plannedPaidBy,
                                onSave: saveTrip, onDiscard: discardTrip)
            }
            .sheet(isPresented: $showingVehiclePicker) {
                VehiclePickerSheet(vehicles: vehicles, selected: $selectedVehicle)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Setup / scheduled start

    private func setup() {
        // Permission + location startup happen in `.task` (activateIdle) to keep first render cheap.
        if selectedVehicle == nil {
            selectedVehicle = vehicles.first(where: { $0.name == scheduled?.vehicleName }) ?? vehicles.first
        }
        if !isModal {
            recovered = LocationTracker.recoverableSession()
        }
        // Auto-start a scheduled drive once, pre-loaded with its destination & schedule timing.
        if let scheduled, !didAutoStart {
            didAutoStart = true
            tracker.destination = scheduled.endCoordinate
            tracker.destinationName = scheduled.endAddress
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
            if let dest = tracker.destination {
                Annotation(tracker.destinationName ?? "Destination", coordinate: dest) {
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
        .onChange(of: tracker.currentLocation?.latitude) { _, _ in
            // While locked on, keep the camera centered on the current location.
            // MapKit interpolates camera moves itself; avoid stacking explicit animations.
            if followUser, let loc = tracker.currentLocation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: loc,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
            }
        }
        .ignoresSafeArea(edges: .top)
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
                Text("ETA").font(.caption2).foregroundStyle(.secondary)
                if let eta = tracker.etaDate {
                    Text(eta, format: .dateTime.hour().minute())
                        .font(.headline).fontDesign(.rounded)
                } else {
                    Text("—").font(.headline)
                }
                if let dest = tracker.destinationName {
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
            Button("Save") { Task { await saveRecovered(rec) } }
                .font(.caption.weight(.bold)).buttonStyle(.borderedProminent)
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
                stopButton
            } else {
                startButton
            }
        }
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
            withAnimation(.spring(duration: 0.4)) { tracker.stopTracking() }
            showingSummary = true
        } label: {
            controlLabel("Stop", "stop.fill", .red)
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
    }

    private func saveTrip(category: TripCategory, paidBy: PaidBy, notes: String?) {
        let pts = tracker.points
        let scheduledDeparture = tracker.scheduledDeparture
        let scheduledArrival = tracker.scheduledArrival
        let tripName = tracker.tripName
        let destName = tracker.destinationName
        let schedStart = scheduled?.startAddress
        let vehName = selectedVehicle?.name
        let vehMpg = selectedVehicle?.avgMpg
        // Dismiss + clear the crash log *synchronously* so the trip can't be saved twice (a second
        // Save tap during the async save, or a stale crash-recovery) creating a duplicate.
        tracker.clearCrashLog()
        showingSummary = false
        // The scheduled occurrence is done — drop it off the departures board.
        scheduled?.lastCompletedAt = .now
        try? context.save()
        guard let start = pts.first?.coordinate, let end = pts.last?.coordinate else {
            if isModal { dismiss() }
            return
        }
        Task { @MainActor in
            let startAddr: String
            if let schedStart { startAddr = schedStart } else { startAddr = await reverseGeocode(start) }
            let endAddr: String
            if let destName { endAddr = destName } else { endAddr = await reverseGeocode(end) }
            let input = TripStore.Input(
                points: pts, startAddress: startAddr, endAddress: endAddr,
                category: category, paidBy: paidBy, notes: notes, name: tripName,
                vehicleName: vehName, vehicleMpg: vehMpg,
                scheduledDeparture: scheduledDeparture, scheduledArrival: scheduledArrival
            )
            await TripStore.save(input, context: context)
        }
        if isModal { dismiss() }
    }

    private func discardTrip() {
        tracker.clearCrashLog()
        showingSummary = false
        if isModal { dismiss() }
    }

    private func saveRecovered(_ rec: DriveLogger.Recovered) async {
        let veh = vehicles.first(where: { $0.name == rec.meta.vehicleName })
        guard let start = rec.points.first?.coordinate, let end = rec.points.last?.coordinate else { return }
        let startAddr = await reverseGeocode(start)
        let endAddr: String
        if let dn = rec.meta.destinationName { endAddr = dn } else { endAddr = await reverseGeocode(end) }
        let input = TripStore.Input(
            points: rec.points, startAddress: startAddr, endAddress: endAddr,
            category: TripCategory(rawValue: rec.meta.category) ?? .other, paidBy: .myself,
            notes: "Recovered drive", name: nil,
            vehicleName: rec.meta.vehicleName, vehicleMpg: veh?.avgMpg,
            scheduledDeparture: nil, scheduledArrival: rec.meta.scheduledArrival
        )
        await TripStore.save(input, context: context)
        LocationTracker.discardRecoverableSession()
        recovered = nil
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
