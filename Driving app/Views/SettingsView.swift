import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [UserSettings]
    @Query private var vehicles: [Vehicle]

    @State private var budget = ""
    @State private var unit = "miles"
    @State private var showingVehicleForm = false
    @State private var vehicleName = ""
    @State private var vehicleMake = ""
    @State private var vehicleModel = ""
    @State private var vehicleYear = ""
    @State private var vehicleTank = ""
    @State private var vehicleMpg = ""

    private var currentSettings: UserSettings {
        if let s = settings.first { return s }
        let s = UserSettings()
        modelContext.insert(s)
        return s
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Monthly Gas Budget") {
                    HStack {
                        Text("$")
                        TextField("0", text: $budget)
                            .keyboardType(.decimalPad)
                            .onAppear { budget = String(format: "%.0f", currentSettings.monthlyBudget) }
                    }
                    Button("Save Budget") {
                        currentSettings.monthlyBudget = Double(budget) ?? 0
                    }
                    Text("Set to 0 to disable budget tracking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Distance Unit") {
                    Picker("Unit", selection: $unit) {
                        Text("Miles").tag("miles")
                        Text("Kilometers").tag("km")
                    }
                    .pickerStyle(.segmented)
                    .onAppear { unit = currentSettings.distanceUnit }
                    .onChange(of: unit) { _, newValue in
                        currentSettings.distanceUnit = newValue
                    }
                }

                Section {
                    ForEach(vehicles) { vehicle in
                        HStack {
                            Image(systemName: "car.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vehicle.name)
                                    .fontWeight(.medium)
                                HStack(spacing: 8) {
                                    if let details = vehicleDetails(vehicle), !details.isEmpty {
                                        Text(details)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let mpg = vehicle.avgMpg {
                                    Text(String(format: "%.0f MPG", mpg))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.blue)
                                }
                                if let tank = vehicle.tankSize {
                                    Text(String(format: "%.0f gal tank", tank))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            modelContext.delete(vehicles[i])
                        }
                    }

                    Button {
                        showingVehicleForm.toggle()
                    } label: {
                        Label(showingVehicleForm ? "Cancel" : "Add Vehicle", systemImage: showingVehicleForm ? "xmark" : "plus")
                    }

                    if showingVehicleForm {
                        TextField("Nickname *", text: $vehicleName)
                        HStack {
                            TextField("Make", text: $vehicleMake)
                            TextField("Model", text: $vehicleModel)
                        }
                        HStack {
                            TextField("Year", text: $vehicleYear)
                                .keyboardType(.numberPad)
                            TextField("Tank (gal)", text: $vehicleTank)
                                .keyboardType(.decimalPad)
                        }
                        HStack {
                            Text("Avg MPG")
                                .foregroundStyle(.secondary)
                            TextField("e.g. 28", text: $vehicleMpg)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("MPG is used to estimate gas usage during tracked trips")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("Save Vehicle") {
                            let v = Vehicle(
                                name: vehicleName,
                                make: vehicleMake.isEmpty ? nil : vehicleMake,
                                model: vehicleModel.isEmpty ? nil : vehicleModel,
                                year: Int(vehicleYear),
                                tankSize: Double(vehicleTank),
                                avgMpg: Double(vehicleMpg)
                            )
                            modelContext.insert(v)
                            vehicleName = ""; vehicleMake = ""; vehicleModel = ""
                            vehicleYear = ""; vehicleTank = ""; vehicleMpg = ""
                            showingVehicleForm = false
                        }
                        .disabled(vehicleName.isEmpty)
                    }
                } header: {
                    Text("Vehicles")
                } footer: {
                    Text("Add vehicles with their MPG to get gas estimates during live tracking.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func vehicleDetails(_ v: Vehicle) -> String? {
        let parts = [v.year.map(String.init), v.make, v.model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
