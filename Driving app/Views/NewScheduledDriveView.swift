import SwiftUI
import SwiftData
import MapKit

/// Create a scheduled drive. Arrival auto-fills from the predicted travel time (MapKit ETA)
/// between the start and destination, and the drive can repeat.
struct NewScheduledDriveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var vehicles: [Vehicle]

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

    private var arrival: Date {
        arrivalOverride ?? departure.addingTimeInterval(TimeInterval(travelSeconds ?? 0))
    }

    private var canSave: Bool {
        !title.isEmpty && startCoord != nil && endCoord != nil && travelSeconds != nil
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
                        Text(routeError).font(.caption).foregroundStyle(.orange)
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
            .navigationTitle("New Scheduled Drive")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
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
            routeError = "Couldn't compute a driving route."
        }
    }

    private func save() {
        guard let s = startCoord, let e = endCoord, let travel = travelSeconds else { return }
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
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? Date()
    }
}
