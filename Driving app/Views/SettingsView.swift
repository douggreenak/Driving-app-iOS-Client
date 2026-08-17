import SwiftUI
import SwiftData
import CoreLocation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var settings: [UserSettings]
    @Query private var vehicles: [Vehicle]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]
    @State private var showingAddBookmark = false

    @State private var budget = ""
    @State private var fuelPrice = ""
    @State private var unit = "miles"
    @State private var defaultPayer: String = PayerGroup.selfKey
    @State private var showingVehicleForm = false
    @State private var vehicleName = ""
    @State private var vehicleMake = ""
    @State private var vehicleModel = ""
    @State private var vehicleYear = ""
    @State private var vehicleTank = ""
    @State private var vehicleMpg = ""
    @State private var showingPayerGroupForm = false
    @State private var payerGroupName = ""
    @State private var payerGroupIcon = "person.fill"
    @State private var payerGroupColor = "purple"
    @State private var pendingVehicleDelete: Vehicle?
    @State private var pendingPlaceDelete: SavedPlace?
    @State private var pendingPayerGroupArchive: PayerGroup?
    @State private var savedFlash = false
    /// Guards the one-time field load below — see its comment.
    @State private var didLoadFields = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportedFiles: [URL] = []
    @State private var showingExportShare = false

    /// Active (non-archived) groups, in display order — everywhere in this view that needs "the
    /// current list of payers" reads this instead of the raw query.
    private var activePayerGroups: [PayerGroup] { payerGroups.filter { !$0.isArchived } }

    /// A pure read — no inserting side effect. This used to insert a fresh `UserSettings` into the
    /// context whenever `settings.first` was nil, but `currentSettings` is a *computed property*
    /// read from several `.onAppear`s in the same `Form` — a `Form`'s rows are a lazy list, so on a
    /// fresh install (before `@Query settings` had republished the first insert) multiple rows could
    /// each see `settings.first == nil` in the same frame and each insert their own row, leaving
    /// several `UserSettings` behind. Whichever one `settings.first` happened to return from then on
    /// was arbitrary, so a saved fuel price or default payer could silently "not take" if it landed
    /// on a different row than the one other screens (`StatsView`, `DriveHomeView`) read. A row is
    /// now seeded exactly once at app launch (`ContentView`'s seed task, alongside
    /// `PayerGroupStore.seedIfNeeded`); this transient fallback only covers the brief window before
    /// that completes, and deliberately does NOT insert, so it can't create a duplicate itself.
    private var currentSettings: UserSettings { settings.first ?? UserSettings() }

    var body: some View {
        NavigationStack {
            Form {
                Section("Monthly Gas Budget") {
                    HStack {
                        Text("$")
                        TextField("0", text: $budget)
                            .keyboardType(.decimalPad)
                    }
                    Button("Save Budget") {
                        currentSettings.monthlyBudget = Double(budget) ?? 0
                        try? modelContext.save()
                        Haptics.success()
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
                        Text("/ gal").foregroundStyle(.secondary)
                    }
                    Button {
                        currentSettings.fuelPricePerGallon = Double(fuelPrice) ?? 3.75
                        try? modelContext.save()
                        Haptics.success()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { savedFlash = true }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation(.easeOut(duration: 0.3)) { savedFlash = false }
                        }
                    } label: {
                        if savedFlash {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Text("Save Price")
                        }
                    }
                } header: {
                    Text("Fuel Price")
                } footer: {
                    Text("Used to estimate how much each drive's gas costs — and who's paying — on the dashboard.")
                }

                Section {
                    ForEach(activePayerGroups) { group in
                        HStack(spacing: 12) {
                            Image(systemName: group.icon)
                                .foregroundStyle(group.color)
                                .frame(width: 24)
                            Text(group.name).fontWeight(.medium)
                            Spacer()
                            if group.isBuiltIn {
                                Text("Built-in").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        // Built-in groups (Me/Parents) offer no delete affordance — skip them so a
                        // swipe that happens to land on one is a no-op instead of archiving it.
                        let rows = activePayerGroups
                        if let i = indexSet.first, !rows[i].isBuiltIn { pendingPayerGroupArchive = rows[i] }
                    }

                    Button {
                        showingPayerGroupForm.toggle()
                    } label: {
                        Label(showingPayerGroupForm ? "Cancel" : "Add Payer Group",
                              systemImage: showingPayerGroupForm ? "xmark" : "plus")
                    }

                    if showingPayerGroupForm {
                        TextField("Name *", text: $payerGroupName)
                        HStack(spacing: 10) {
                            ForEach(PayerGroup.iconPresets, id: \.self) { icon in
                                Button { payerGroupIcon = icon } label: {
                                    Image(systemName: icon)
                                        .font(.subheadline)
                                        .foregroundStyle(payerGroupIcon == icon ? .white : .secondary)
                                        .frame(width: 30, height: 30)
                                        .background(payerGroupIcon == icon ? PayerGroup.color(for: payerGroupColor) : Color(.systemGray5),
                                                   in: .circle)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 10) {
                            ForEach(PayerGroup.colorPresets, id: \.name) { preset in
                                Button { payerGroupColor = preset.name } label: {
                                    Circle().fill(preset.color).frame(width: 26, height: 26)
                                        .overlay(Circle().stroke(.white, lineWidth: payerGroupColor == preset.name ? 2 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button("Save Group") {
                            let nextOrder = (payerGroups.map(\.sortOrder).max() ?? -1) + 1
                            let key = "GROUP_\(UUID().uuidString.prefix(8))"
                            let g = PayerGroup(key: key, name: payerGroupName, icon: payerGroupIcon,
                                              colorName: payerGroupColor, sortOrder: nextOrder)
                            modelContext.insert(g)
                            try? modelContext.save()
                            Haptics.success()
                            payerGroupName = ""; payerGroupIcon = "person.fill"; payerGroupColor = "purple"
                            showingPayerGroupForm = false
                        }
                        .disabled(payerGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Picker("Default payer", selection: $defaultPayer) {
                        ForEach(activePayerGroups) { group in
                            Label(group.name, systemImage: group.icon).tag(group.key)
                        }
                    }
                    .onChange(of: defaultPayer) { _, newValue in
                        // Guard against the load-on-appear flip firing a spurious save + haptic:
                        // onAppear can change defaultPayer, which trips onChange even though nothing
                        // was persisted yet. Only write real edits.
                        guard newValue != currentSettings.defaultPaidByRaw else { return }
                        currentSettings.defaultPaidByRaw = newValue
                        try? modelContext.save()
                        Haptics.tap()
                    }
                } header: {
                    Text("Who Pays for Gas")
                } footer: {
                    Text("The default payer for drives you start ad-hoc (Start a Drive or Go to). Scheduled drives use the payer set on the schedule, and you can still change any drive's payer afterward. Removing a group hides it from pickers but keeps its name on drives/fill-ups already logged with it.")
                }

                Section("Distance Unit") {
                    Picker("Unit", selection: $unit) {
                        Text("Miles").tag("miles")
                        Text("Kilometers").tag("km")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: unit) { _, newValue in
                        currentSettings.distanceUnit = newValue
                        try? modelContext.save()
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
                        if let i = indexSet.first { pendingPlaceDelete = savedPlaces[i] }
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
                        NavigationLink {
                            EditVehicleView(vehicle: vehicle)
                        } label: {
                            HStack {
                                Image(systemName: "car.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vehicle.name)
                                        .fontWeight(.medium)
                                    if let details = vehicleDetails(vehicle), !details.isEmpty {
                                        Text(details)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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
                                        Text(String(format: "%.0f-gal tank", tank))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        if let i = indexSet.first { pendingVehicleDelete = vehicles[i] }
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
                            try? modelContext.save()
                            Haptics.success()
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

                Section {
                    Button {
                        exportDatabase()
                    } label: {
                        if exporting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Preparing Export…")
                            }
                        } else {
                            Label("Export Database", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(exporting)
                    if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Saves a copy of everything on this phone — trips, schedules, vehicles, and settings — as SQLite database files you can back up or open elsewhere. This only reads a copy; nothing here is deleted or changed.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .keyboardDismissable()
            // Loads every field exactly once, instead of each row's own `.onAppear` — a `Form`'s
            // rows are a lazy list, so scrolling a row off-screen and back re-fires `.onAppear`,
            // silently overwriting whatever the user had just typed (e.g. type a new budget, scroll
            // down to Vehicles, scroll back up, and the field had reverted to the old saved value).
            .task {
                guard !didLoadFields else { return }
                didLoadFields = true
                budget = String(format: "%.0f", currentSettings.monthlyBudget)
                fuelPrice = String(format: "%.2f", currentSettings.fuelPricePerGallon)
                defaultPayer = currentSettings.defaultPaidByRaw
                unit = currentSettings.distanceUnit
            }
            .sheet(isPresented: $showingAddBookmark) {
                AddBookmarkView(nextOrder: (savedPlaces.map(\.sortOrder).max() ?? -1) + 1)
            }
            #if canImport(UIKit)
            .sheet(isPresented: $showingExportShare) {
                ActivityShareSheet(items: exportedFiles)
            }
            #endif
            .confirmationDialog("Delete this vehicle?",
                                isPresented: Binding(get: { pendingVehicleDelete != nil },
                                                     set: { if !$0 { pendingVehicleDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Vehicle", role: .destructive) {
                    if let v = pendingVehicleDelete { Haptics.warning(); modelContext.delete(v) }
                    pendingVehicleDelete = nil
                }
            } message: {
                Text("Trips recorded in this car keep their data but will no longer link to it.")
            }
            .confirmationDialog("Delete this place?",
                                isPresented: Binding(get: { pendingPlaceDelete != nil },
                                                     set: { if !$0 { pendingPlaceDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Place", role: .destructive) {
                    if let p = pendingPlaceDelete { Haptics.warning(); modelContext.delete(p) }
                    pendingPlaceDelete = nil
                }
            }
            .confirmationDialog("Remove this payer group?",
                                isPresented: Binding(get: { pendingPayerGroupArchive != nil },
                                                     set: { if !$0 { pendingPayerGroupArchive = nil } }),
                                titleVisibility: .visible) {
                Button("Remove Group", role: .destructive) {
                    if let g = pendingPayerGroupArchive {
                        Haptics.warning()
                        g.isArchived = true
                        // A default payer pointing at the group being removed would otherwise pick a
                        // hidden option in the picker above — fall back to the built-in "Me".
                        if currentSettings.defaultPaidByRaw == g.key {
                            currentSettings.defaultPaidByRaw = PayerGroup.selfKey
                            defaultPayer = PayerGroup.selfKey
                        }
                        try? modelContext.save()
                    }
                    pendingPayerGroupArchive = nil
                }
            } message: {
                Text("Drives and fill-ups already logged with it keep showing its name — it just won't be offered for new ones.")
            }
        }
    }

    private func vehicleDetails(_ v: Vehicle) -> String? {
        let parts = [v.year.map(String.init), v.make, v.model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Database export

    /// Exports a COPY of the on-device SwiftData/SQLite store — never touches, moves, or deletes the
    /// live files the app is actually running on, so a failed or interrupted export can't disrupt
    /// real data. SQLite (SwiftData's storage) keeps its store as up to three files sharing a base
    /// name — the main `.sqlite`, and `-wal`/`-shm` sidecars that hold recently-written data not yet
    /// folded into the main file. Copying only the main file could silently omit very recent writes;
    /// all three (whichever exist) are copied together so the export is a complete, consistent
    /// snapshot that opens correctly in any SQLite browser.
    private func exportDatabase() {
        exportError = nil
        exporting = true
        Task {
            defer { exporting = false }
            // Flush any pending in-memory changes first so the exported copy is fully current —
            // a normal save, no different from what every other Save button in this screen already
            // does; it doesn't touch the export files themselves.
            try? modelContext.save()

            guard let storeURL = modelContext.container.configurations.first?.url else {
                exportError = "Couldn't locate the database file."
                return
            }
            let fm = FileManager.default
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let exportDir = fm.temporaryDirectory.appendingPathComponent("DriveTrackerExport-\(stamp)", isDirectory: true)
            do {
                try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
                var copied: [URL] = []
                for suffix in ["", "-wal", "-shm"] {
                    let source = URL(fileURLWithPath: storeURL.path + suffix)
                    guard fm.fileExists(atPath: source.path) else { continue }
                    let dest = exportDir.appendingPathComponent(source.lastPathComponent)
                    try fm.copyItem(at: source, to: dest)
                    copied.append(dest)
                }
                guard !copied.isEmpty else {
                    exportError = "No database file found to export."
                    return
                }
                exportedFiles = copied
                showingExportShare = true
            } catch {
                exportError = "Couldn't prepare the export: \(error.localizedDescription)"
            }
        }
    }
}

/// Edit a car's name, details, and MPG. Changing the name or MPG retroactively updates every past
/// trip recorded in that car.
struct EditVehicleView: View {
    @Bindable var vehicle: Vehicle
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var make: String
    @State private var model: String
    @State private var year: String
    @State private var tank: String
    @State private var mpg: String

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        _name = State(initialValue: vehicle.name)
        _make = State(initialValue: vehicle.make ?? "")
        _model = State(initialValue: vehicle.model ?? "")
        _year = State(initialValue: vehicle.year.map(String.init) ?? "")
        _tank = State(initialValue: vehicle.tankSize.map { String(format: "%.0f", $0) } ?? "")
        _mpg = State(initialValue: vehicle.avgMpg.map { String(format: "%.0f", $0) } ?? "")
    }

    var body: some View {
        Form {
            Section("Car") {
                TextField("Nickname", text: $name)
                HStack {
                    TextField("Make", text: $make)
                    TextField("Model", text: $model)
                }
                HStack {
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Tank (gal)", text: $tank).keyboardType(.decimalPad)
                }
            }
            Section {
                HStack {
                    Text("Avg MPG").foregroundStyle(.secondary)
                    Spacer()
                    TextField("e.g. 28", text: $mpg)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Changing the MPG recalculates the estimated gas used — and the paid-by cost — for every past trip recorded in this car.")
            }
            Section {
                Button {
                    vehicle.lastFilledUp = Date()
                    try? context.save()
                    Haptics.success()
                } label: {
                    Label("Mark Filled Up Now", systemImage: "fuelpump.fill")
                }
                if let filled = vehicle.lastFilledUp {
                    HStack {
                        Text("Last fill-up").foregroundStyle(.secondary)
                        Spacer()
                        Text(filled, format: .dateTime.month().day().hour().minute())
                        Button {
                            vehicle.lastFilledUp = nil
                            try? context.save()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("The gas price only applies to fuel burned since the last fill-up for this car.")
            }
        }
        .navigationTitle(vehicle.name)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.isEmpty) }
        }
    }

    private func save() {
        let oldName = vehicle.name
        vehicle.name = name
        vehicle.make = make.isEmpty ? nil : make
        vehicle.model = model.isEmpty ? nil : model
        vehicle.year = Int(year)
        vehicle.tankSize = Double(tank)
        vehicle.avgMpg = Double(mpg)
        try? context.save()
        // Retroactively re-point + recompute fuel for this car's past trips.
        TripStore.updateTripsForVehicle(oldName: oldName, newName: vehicle.name,
                                        newMpg: vehicle.avgMpg, context: context)
        dismiss()
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
