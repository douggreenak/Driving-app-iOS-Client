import SwiftUI
import SwiftData

struct NewGasEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]
    @Query(sort: \DriveTrip.date) private var trips: [DriveTrip]
    var onSaved: (() async -> Void)?

    @State private var date = Date.now
    @State private var gallons = ""
    @State private var pricePerGallon = ""
    @State private var paidBy: String = PayerGroup.selfKey
    @State private var fuelType: FuelType = .regular
    @State private var stationName = ""
    @State private var odometer = ""
    @State private var vehicleName: String?
    @State private var saving = false

    private var totalCost: Double {
        (Double(gallons) ?? 0) * (Double(pricePerGallon) ?? 0)
    }

    private var selectedVehicle: Vehicle? { vehicles.first { $0.name == vehicleName } }

    /// What the app's speed-aware fuel model estimates was burned since this vehicle's last fill-up
    /// (or across all recorded history if it has none), so the estimate is visible before saving too —
    /// not just after, in the Gas list.
    private var estimatedBurnedSinceLastFillUp: Double? {
        guard let name = vehicleName else { return nil }
        let amount = FuelModel.estimatedGallonsBurned(
            vehicleName: name, since: selectedVehicle?.lastFilledUp, through: date, trips: trips)
        return amount > 0.01 ? amount : nil
    }

    /// Require valid, positive gallons & price before the entry can be saved.
    private var canSave: Bool {
        guard let g = Double(gallons), g > 0, let p = Double(pricePerGallon), p > 0 else { return false }
        return !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Text("Total").font(.caption).foregroundStyle(.secondary)
                        Text(totalCost, format: .currency(code: "USD"))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }

                Section("Who's Paying?") {
                    Picker("Paid by", selection: $paidBy) {
                        ForEach(payerGroups.filter { !$0.isArchived }) { group in
                            Label(group.name, systemImage: group.icon).tag(group.key)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !vehicles.isEmpty {
                    Section {
                        Picker("Car", selection: $vehicleName) {
                            Text("None").tag(String?.none)
                            ForEach(vehicles) { vehicle in
                                Text(vehicle.name).tag(String?.some(vehicle.name))
                            }
                        }
                        if let estimate = estimatedBurnedSinceLastFillUp {
                            Text(String(format: "Since your last fill-up, trips are estimated to have used ~%.1f gal.", estimate))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Vehicle")
                    }
                }

                Section("Fuel Type") {
                    Picker("Type", selection: $fuelType) {
                        ForEach(FuelType.allCases, id: \.self) { Text($0.shortLabel).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Text("Gallons"); Spacer()
                        TextField("0.00", text: $gallons)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Price/Gallon"); Spacer()
                        TextField("0.00", text: $pricePerGallon)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }

                Section("Optional") {
                    TextField("Station Name", text: $stationName)
                    HStack {
                        Text("Odometer"); Spacer()
                        TextField("Miles", text: $odometer)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Add Gas")
            .navigationBarTitleDisplayMode(.inline)
            // Default the picker to the only/most likely car so a fill-up is attributed by default.
            .onAppear { if vehicleName == nil { vehicleName = vehicles.first?.name } }
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        saving = true
        Haptics.success()
        let f = ISO8601DateFormatter()
        Task {
            let create = APIGasEntryCreate(
                date: f.string(from: date),
                gallons: Double(gallons) ?? 0,
                pricePerGallon: Double(pricePerGallon) ?? 0,
                paidBy: paidBy,
                fuelType: fuelType.rawValue,
                stationName: stationName.isEmpty ? nil : stationName,
                odometer: Double(odometer),
                vehicleName: vehicleName
            )
            _ = try? await APIClient.createGasEntry(create)
            await onSaved?()
            dismiss()
        }
    }
}
