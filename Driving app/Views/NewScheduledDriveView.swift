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
    @State private var travelSeconds: Int?
    @State private var arrivalOverride: Date?
    @State private var calculating = false
    @State private var routeError: String?
    @State private var didPrefill = false

    init(editing: ScheduledDrive? = nil) {
        self.editing = editing
        if let d = editing {
            _title = State(initialValue: d.title)
            _startAddress = State(initialValue: d.startAddress)
            _endAddress = State(initialValue: d.endAddress)
            _departure = State(initialValue: d.departure)
            _repeatRule = State(initialValue: d.repeatRule)
            _category = State(initialValue: d.category)
            _paidBy = State(initialValue: d.paidBy)
            _vehicleName = State(initialValue: d.vehicleName)
            _notes = State(initialValue: d.notes ?? "")
            _startCoord = State(initialValue: d.startCoordinate)
            _endCoord = State(initialValue: d.endCoordinate)
            _travelSeconds = State(initialValue: d.estimatedTravelTime)
            _arrivalOverride = State(initialValue: d.scheduledArrival)
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
                    Button(editing == nil ? "Save" : "Done") { save() }.disabled(!canSave)
                }
            }
        }
    }

    /// Recompute the predicted travel time whenever both endpoints are set.
    private func recalcETA() async {
        guard let s = startCoord, let e = endCoord else { return }
        calculating = true
        routeError = nil
        defer { calculating = false }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: .init(coordinate: s))
        request.destination = MKMapItem(placemark: .init(coordinate: e))
        request.transportType = .automobile
        do {
            let eta = try await MKDirections(request: request).calculateETA()
            travelSeconds = Int(eta.expectedTravelTime)
            arrivalOverride = nil
        } catch {
            routeError = "Couldn't find a driving route between these two places. Check the addresses and your connection."
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

    private func save() {
        guard let s = startCoord, let e = endCoord, let travel = travelSeconds else { return }
        Haptics.success()
        if let drive = editing {
            drive.title = title
            drive.startAddress = startAddress
            drive.endAddress = endAddress
            drive.startLat = s.latitude; drive.startLng = s.longitude
            drive.endLat = e.latitude; drive.endLng = e.longitude
            drive.departure = departure
            drive.estimatedTravelTime = travel
            drive.scheduledArrival = arrival
            drive.repeatRule = repeatRule
            drive.category = category
            drive.paidBy = paidBy
            drive.vehicleName = vehicleName
            drive.notes = notes.isEmpty ? nil : notes
        } else {
            let drive = ScheduledDrive(
                title: title,
                startAddress: startAddress, endAddress: endAddress,
                startLat: s.latitude, startLng: s.longitude,
                endLat: e.latitude, endLng: e.longitude,
                departure: departure,
                estimatedTravelTime: travel,
                scheduledArrival: arrival,
                repeatRule: repeatRule,
                category: category,
                paidBy: paidBy,
                vehicleName: vehicleName,
                notes: notes.isEmpty ? nil : notes
            )
            context.insert(drive)
        }
        try? context.save()
        dismiss()
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
