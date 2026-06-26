import SwiftUI
import SwiftData

struct NewGasEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var date = Date.now
    @State private var gallons = ""
    @State private var pricePerGallon = ""
    @State private var paidBy: PaidBy = .myself
    @State private var fuelType: FuelType = .regular
    @State private var stationName = ""
    @State private var odometer = ""

    private var totalCost: Double {
        (Double(gallons) ?? 0) * (Double(pricePerGallon) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Text("Total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(totalCost, format: .currency(code: "USD"))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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
                        ForEach(FuelType.allCases, id: \.self) { ft in
                            Text(ft.label).tag(ft)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    HStack {
                        Text("Gallons")
                        Spacer()
                        TextField("0.00", text: $gallons)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Price/Gallon")
                        Spacer()
                        TextField("0.00", text: $pricePerGallon)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Optional") {
                    TextField("Station Name", text: $stationName)
                    HStack {
                        Text("Odometer")
                        Spacer()
                        TextField("Miles", text: $odometer)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Add Gas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(gallons.isEmpty || pricePerGallon.isEmpty)
                }
            }
        }
    }

    private func save() {
        let entry = GasEntry(
            date: date,
            gallons: Double(gallons) ?? 0,
            pricePerGallon: Double(pricePerGallon) ?? 0,
            paidBy: paidBy,
            fuelType: fuelType,
            stationName: stationName.isEmpty ? nil : stationName,
            odometer: Double(odometer)
        )
        modelContext.insert(entry)
        dismiss()
    }
}
