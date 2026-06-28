import SwiftUI

struct NewGasEntryView: View {
    @Environment(\.dismiss) private var dismiss
    var onSaved: (() async -> Void)?

    @State private var date = Date.now
    @State private var gallons = ""
    @State private var pricePerGallon = ""
    @State private var paidBy: PaidBy = .myself
    @State private var fuelType: FuelType = .regular
    @State private var stationName = ""
    @State private var odometer = ""
    @State private var saving = false

    private var totalCost: Double {
        (Double(gallons) ?? 0) * (Double(pricePerGallon) ?? 0)
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
                        Text("Me").tag(PaidBy.myself)
                        Text("Parents").tag(PaidBy.parents)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Fuel Type") {
                    Picker("Type", selection: $fuelType) {
                        ForEach(FuelType.allCases, id: \.self) { Text($0.label).tag($0) }
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
                paidBy: paidBy.rawValue,
                fuelType: fuelType.rawValue,
                stationName: stationName.isEmpty ? nil : stationName,
                odometer: Double(odometer)
            )
            _ = try? await APIClient.createGasEntry(create)
            await onSaved?()
            dismiss()
        }
    }
}
