import SwiftUI
import SwiftData
import MapKit

/// Create a scheduled drive. Arrival auto-fills from the predicted travel time (MapKit ETA)
/// between the start and destination, and the drive can repeat.
struct NewScheduledDriveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var vehicles: [Vehicle]
    /// Most-recent schedules first — used to prefill non-location/time details on a new drive.
    @Query(sort: \ScheduledDrive.createdAt, order: .reverse) private var recentDrives: [ScheduledDrive]

    /// When non-nil the form edits this existing drive in place rather than creating a new one.
    private let editing: ScheduledDrive?
    /// The specific occurrence being edited (for a repeating drive), so "change only this one" can
    /// target the right date.
    private let occurrenceDate: Date?

    @State private var showRepeatChoice = false

    /// Which occurrences an edit to a repeating drive applies to.
    private enum EditScope { case all, thisOccurrence }

    @State private var title = ""
    @State private var startAddress = ""
    @State private var endAddress = ""
    @State private var departure = defaultDeparture()
    @State private var repeatRule: RepeatRule = .weekdays
    @State private var category: TripCategory = .work
    @State private var paidBy: PaidBy = .myself
    @State private var vehicleName: String?
    @State private var notes = ""

    @State private var startCoord: CLLocationCoordinate2D?
    @State private var endCoord: CLLocationCoordinate2D?
    /// Intermediate stops (multi-stop): start → stops → destination.
    @State private var stops: [RouteStop] = []
    @State private var travelSeconds: Int?
    @State private var arrivalOverride: Date?
    @State private var calculating = false
    @State private var routeError: String?
    @State private var didPrefill = false

    init(editing: ScheduledDrive? = nil, occurrenceDate: Date? = nil) {
        self.editing = editing
        self.occurrenceDate = occurrenceDate
        if let d = editing {
            _title = State(initialValue: d.title)
            _startAddress = State(initialValue: d.startAddress)
            _endAddress = State(initialValue: d.endAddress)
            // For a repeating drive opened on a specific occurrence, show THAT occurrence's
            // departure/arrival (not the series anchor), so editing it reads naturally.
            let budget = d.scheduledArrival.timeIntervalSince(d.departure)
            let dep = (d.repeatRule != .none ? occurrenceDate : nil) ?? d.departure
            _departure = State(initialValue: dep)
            _arrivalOverride = State(initialValue: dep.addingTimeInterval(budget))
            _repeatRule = State(initialValue: d.repeatRule)
            _category = State(initialValue: d.category)
            _paidBy = State(initialValue: d.paidBy)
            _vehicleName = State(initialValue: d.vehicleName)
            _notes = State(initialValue: d.notes ?? "")
            _startCoord = State(initialValue: d.startCoordinate)
            _endCoord = State(initialValue: d.endCoordinate)
            _stops = State(initialValue: d.stops)
            _travelSeconds = State(initialValue: d.estimatedTravelTime)
        }
    }

    private var arrival: Date {
        arrivalOverride ?? departure.addingTimeInterval(TimeInterval(travelSeconds ?? 0))
    }

    /// Start and destination must be meaningfully different (not the same pin).
    private var sameStartAndEnd: Bool {
        guard let s = startCoord, let e = endCoord else { return false }
        return s.distanceMeters(to: e) < 50
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && startCoord != nil && endCoord != nil && travelSeconds != nil && !sameStartAndEnd
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Drive") {
                    TextField("Title (e.g. Morning Commute)", text: $title)
                    AddressPickerRow(title: "Start", systemImage: "flag.fill",
                                     address: $startAddress, coordinate: $startCoord) {
                        Task { await recalcETA() }
                    }
                    ForEach(Array(stops.enumerated()), id: \.element.id) { index, _ in
                        HStack(spacing: 8) {
                            AddressPickerRow(title: "Stop \(index + 1)",
                                             systemImage: "\(index + 1).circle.fill",
                                             address: stopBinding(index).address,
                                             coordinate: stopBinding(index).coordinate) {
                                Task { await recalcETA() }
                            }
                            Button {
                                stops.remove(at: index)
                                Task { await recalcETA() }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        stops.append(RouteStop(address: "", lat: 0, lng: 0))
                    } label: {
                        Label("Add stop", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    AddressPickerRow(title: "Destination", systemImage: "mappin",
                                     address: $endAddress, coordinate: $endCoord) {
                        Task { await recalcETA() }
                    }
                    if calculating {
                        HStack {
                            ProgressView()
                            Text("Calculating travel time…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let routeError {
                        Label(routeError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if sameStartAndEnd {
                        Label("Start and destination are the same place.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Schedule") {
                    DatePicker("Departure", selection: $departure)
                        .onChange(of: departure) { _, _ in arrivalOverride = nil }

                    HStack {
                        Label("Predicted travel", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(travelSeconds.map(travelString) ?? "—")
                            .foregroundStyle(.secondary)
                    }

                    DatePicker("Arrival (auto-filled)", selection: Binding(
                        get: { arrival },
                        set: { arrivalOverride = $0 }
                    ))
                    .disabled(travelSeconds == nil)
                    if travelSeconds != nil {
                        Text("Auto-filled from the predicted drive time. Adjust if you like.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    Picker("Repeats", selection: $repeatRule) {
                        ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section("Details") {
                    Picker("Paid by", selection: $paidBy) {
                        ForEach(PaidBy.allCases, id: \.self) {
                            Label($0.label, systemImage: $0.icon).tag($0)
                        }
                    }
                    Picker("Category", selection: $category) {
                        ForEach(TripCategory.allCases, id: \.self) {
                            Label($0.label, systemImage: $0.icon).tag($0)
                        }
                    }
                    if !vehicles.isEmpty {
                        Picker("Vehicle", selection: $vehicleName) {
                            Text("None").tag(String?.none)
                            ForEach(vehicles) { v in Text(v.name).tag(String?.some(v.name)) }
                        }
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2)
                }
            }
            .navigationTitle(editing == nil ? "New Scheduled Drive" : "Edit Scheduled Drive")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .onAppear(perform: prefillFromLast)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Save" : "Done") { attemptSave() }.disabled(!canSave)
                }
            }
            .confirmationDialog("This drive repeats", isPresented: $showRepeatChoice, titleVisibility: .visible) {
                Button("Change Only This Drive") { performSave(scope: .thisOccurrence) }
                Button("Change All Future Drives") { performSave(scope: .all) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Apply your changes to just this one occurrence, or to the whole repeating series?")
            }
        }
    }

    /// Bindings into a specific stop, adapting `RouteStop`'s stored lat/lng to the address-picker's
    /// optional-coordinate binding. Bounds-checked so a remove mid-render can't crash.
    private func stopBinding(_ index: Int) -> (address: Binding<String>, coordinate: Binding<CLLocationCoordinate2D?>) {
        let address = Binding<String>(
            get: { index < stops.count ? stops[index].address : "" },
            set: { if index < stops.count { stops[index].address = $0 } }
        )
        let coordinate = Binding<CLLocationCoordinate2D?>(
            get: { index < stops.count && (stops[index].lat != 0 || stops[index].lng != 0) ? stops[index].coordinate : nil },
            set: { newValue in
                guard index < stops.count else { return }
                if let c = newValue { stops[index].lat = c.latitude; stops[index].lng = c.longitude }
                else { stops[index].lat = 0; stops[index].lng = 0 }
            }
        )
        return (address, coordinate)
    }

    /// Stops that have actually been picked (have a coordinate), in order.
    private var pickedStops: [RouteStop] { stops.filter { $0.lat != 0 || $0.lng != 0 } }

    /// Recompute the predicted travel time across every leg (start → stops → destination).
    private func recalcETA() async {
        guard let s = startCoord, let e = endCoord else { return }
        calculating = true
        routeError = nil
        defer { calculating = false }
        let waypoints = [s] + pickedStops.map(\.coordinate) + [e]
        if let result = await RouteMatcher.multiLegRoute(through: waypoints) {
            travelSeconds = result.seconds
            arrivalOverride = nil
        } else {
            routeError = "Couldn't find a driving route through these places. Check the addresses and your connection."
        }
    }

    /// On a brand-new drive, copy the non-location/time details from the most recent schedule so
    /// repeated trips don't have to be reconfigured every time.
    private func prefillFromLast() {
        guard editing == nil, !didPrefill else { return }
        didPrefill = true
        guard let last = recentDrives.first else { return }
        repeatRule = last.repeatRule
        category = last.category
        paidBy = last.paidBy
        vehicleName = last.vehicleName
    }

    /// True when we're editing an existing *repeating* drive — the case where the user must choose
    /// whether the change applies to this one occurrence or the whole series.
    private var editingRepeating: Bool { editing?.repeatRule ?? .none != .none }

    /// Save tap: repeating edits ask "this one vs all"; everything else saves straight through.
    private func attemptSave() {
        guard canSave else { return }
        if editingRepeating {
            showRepeatChoice = true
        } else {
            performSave(scope: .all)
        }
    }

    private func performSave(scope: EditScope) {
        guard let s = startCoord, let e = endCoord, let travel = travelSeconds else { return }
        Haptics.success()
        if let drive = editing, scope == .all {
            // Apply to the whole series (or a one-time drive) — edit in place.
            apply(to: drive, s: s, e: e, travel: travel)
        } else if let drive = editing, scope == .thisOccurrence {
            // Change only this occurrence: skip it in the series and drop in a standalone one-time
            // drive carrying the edits. No new data model needed — reuses the skip mechanism.
            let original = (occurrenceDate ?? drive.statusReferenceDeparture())
            drive.skippedOccurrences.append(original)
            let one = makeDrive(s: s, e: e, travel: travel, repeatOverride: RepeatRule.none)
            context.insert(one)
        } else {
            context.insert(makeDrive(s: s, e: e, travel: travel, repeatOverride: nil))
        }
        try? context.save()
        // Best-effort mirror the new/edited drive to the web DB.
        Task { await ScheduledDriveStore.sync(context: context) }
        dismiss()
    }

    private func apply(to drive: ScheduledDrive, s: CLLocationCoordinate2D, e: CLLocationCoordinate2D, travel: Int) {
        drive.title = title
        drive.startAddress = startAddress
        drive.endAddress = endAddress
        drive.startLat = s.latitude; drive.startLng = s.longitude
        drive.endLat = e.latitude; drive.endLng = e.longitude
        drive.departure = departure
        drive.estimatedTravelTime = travel
        drive.scheduledArrival = arrival
        drive.stops = pickedStops
        drive.repeatRule = repeatRule
        drive.category = category
        drive.paidBy = paidBy
        drive.vehicleName = vehicleName
        drive.notes = notes.isEmpty ? nil : notes
    }

    private func makeDrive(s: CLLocationCoordinate2D, e: CLLocationCoordinate2D, travel: Int, repeatOverride: RepeatRule?) -> ScheduledDrive {
        let drive = ScheduledDrive(
            title: title,
            startAddress: startAddress, endAddress: endAddress,
            startLat: s.latitude, startLng: s.longitude,
            endLat: e.latitude, endLng: e.longitude,
            departure: departure,
            estimatedTravelTime: travel,
            scheduledArrival: arrival,
            repeatRule: repeatOverride ?? repeatRule,
            category: category,
            paidBy: paidBy,
            vehicleName: vehicleName,
            notes: notes.isEmpty ? nil : notes
        )
        drive.stops = pickedStops
        return drive
    }

    private func travelString(_ seconds: Int) -> String {
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }

    private static func defaultDeparture() -> Date {
        let cal = Calendar.current
        let now = Date()
        // Default to today at 8 AM; if that's already past, use the next round hour.
        let eightToday = cal.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        if eightToday > now { return eightToday }
        let nextHour = cal.date(byAdding: .hour, value: 1, to: now) ?? now
        return cal.date(bySettingHour: cal.component(.hour, from: nextHour), minute: 0, second: 0, of: now) ?? now
    }
}
