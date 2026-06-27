import SwiftUI
import SwiftData
import CoreLocation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [UserSettings]
    @Query private var vehicles: [Vehicle]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @State private var showingAddBookmark = false

    @State private var budget = ""
    @State private var fuelPrice = ""
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

                Section {
                    HStack {
                        Text("$")
                        TextField("3.75", text: $fuelPrice)
                            .keyboardType(.decimalPad)
                            .onAppear { fuelPrice = String(format: "%.2f", currentSettings.fuelPricePerGallon) }
                        Text("/ gal").foregroundStyle(.secondary)
                    }
                    Button("Save Price") {
                        currentSettings.fuelPricePerGallon = Double(fuelPrice) ?? 3.75
                    }
                } header: {
                    Text("Fuel Price")
                } footer: {
                    Text("Used to estimate how much each drive's gas costs — and who's paying — on the dashboard.")
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
                    ForEach(savedPlaces) { place in
                        HStack(spacing: 12) {
                            Image(systemName: place.icon)
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.label).fontWeight(.medium)
                                Text(place.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { modelContext.delete(savedPlaces[i]) }
                    }

                    Button {
                        showingAddBookmark = true
                    } label: {
                        Label("Add Bookmark", systemImage: "plus")
                    }
                } header: {
                    Text("Saved Places")
                } footer: {
                    Text("Bookmark Home, Shop, School and more for quick address entry when scheduling drives.")
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
            .keyboardDismissable()
            .sheet(isPresented: $showingAddBookmark) {
                AddBookmarkView(nextOrder: (savedPlaces.map(\.sortOrder).max() ?? -1) + 1)
            }
        }
    }

    private func vehicleDetails(_ v: Vehicle) -> String? {
        let parts = [v.year.map(String.init), v.make, v.model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Create a bookmarked place: pick a label/icon and search its address.
struct AddBookmarkView: View {
    let nextOrder: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var label = "Home"
    @State private var icon = "house.fill"
    @State private var customLabel = ""
    @State private var address = ""
    @State private var coordinate: CLLocationCoordinate2D?

    private var isCustom: Bool { label == "Other" }
    private var finalLabel: String { isCustom ? customLabel : label }
    private var canSave: Bool { coordinate != nil && !finalLabel.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    Picker("Type", selection: $label) {
                        ForEach(SavedPlace.presets, id: \.label) { preset in
                            Label(preset.label, systemImage: preset.icon).tag(preset.label)
                        }
                    }
                    .onChange(of: label) { _, new in
                        icon = SavedPlace.presets.first { $0.label == new }?.icon ?? "mappin.circle.fill"
                    }
                    if isCustom {
                        TextField("Custom name", text: $customLabel)
                    }
                }
                Section("Location") {
                    AddressPickerRow(title: "Address", systemImage: icon,
                                     address: $address, coordinate: $coordinate)
                }
            }
            .navigationTitle("Add Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
        }
    }

    private func save() {
        guard let c = coordinate else { return }
        context.insert(SavedPlace(label: finalLabel, address: address,
                                  lat: c.latitude, lng: c.longitude, icon: icon, sortOrder: nextOrder))
        try? context.save()
        dismiss()
    }
}
