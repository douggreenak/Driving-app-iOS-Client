import SwiftUI
import SwiftData
import CoreLocation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ActiveDriveController.self) private var activeDrive
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

    /// Parses a decimal-pad field's text, also accepting a comma decimal separator — the decimal
    /// pad's own separator key types "," in a comma-decimal locale, for which plain `Double(_:)`
    /// returns `nil`. `nil` here means genuinely unparseable/empty, not "default to 0".
    private func parsedAmount(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
    private var budgetValue: Double? { parsedAmount(budget) }
    private var fuelPriceValue: Double? { let v = parsedAmount(fuelPrice); return (v ?? 0) > 0 ? v : nil }

    /// Whether the "Add Vehicle" form's name matches an existing car (case-insensitively) — see the
    /// Save Vehicle button's doc comment.
    private var duplicateVehicleName: Bool {
        let trimmed = vehicleName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return vehicles.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

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
                        guard let v = budgetValue else { return }
                        currentSettings.monthlyBudget = v
                        try? modelContext.save()
                        Haptics.success()
                        // Re-render from the saved value so a locale quirk (see `budgetValue`'s doc
                        // comment) can't leave the field showing something different from what's
                        // actually stored.
                        budget = String(format: "%.0f", v)
                    }
                    // Neither Save button had a `.disabled`, and `Double(_:)` returns `nil` for
                    // anything that doesn't parse — garbage, an empty field, or (in a comma-decimal
                    // locale) the decimal-pad's own separator key producing e.g. "3,75". `?? 0`/
                    // `?? 3.75` swallowed that silently: a success haptic fired, "Saved" flashed
                    // green, and the field kept showing the unparseable text for the rest of the
                    // session (a one-time field load blocks reloading it) while the store actually
                    // held a DIFFERENT number than what was on screen — for budget, silently 0, which
                    // the very next line says means "disable budget tracking".
                    .disabled(budgetValue == nil)
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
                        guard let v = fuelPriceValue else { return }
                        currentSettings.fuelPricePerGallon = v
                        try? modelContext.save()
                        fuelPrice = String(format: "%.2f", v)
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
                    .disabled(fuelPriceValue == nil)
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
                        // Save already clears these three; Cancel used to just collapse the form and
                        // leave whatever had been typed sitting in `@State` — reopening the form
                        // later in the same Settings session (to add a DIFFERENT group) silently
                        // pre-filled it with the abandoned name/icon/color.
                        if showingPayerGroupForm {
                            payerGroupName = ""; payerGroupIcon = "person.fill"; payerGroupColor = "purple"
                        }
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
                                    HStack(spacing: 6) {
                                        Text(vehicle.name)
                                            .fontWeight(.medium)
                                        if vehicleInUseByActiveDrive(vehicle) {
                                            Text("In use").font(.caption2.weight(.bold)).foregroundStyle(.blue)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(.blue.opacity(0.15), in: .capsule)
                                        }
                                    }
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
                        // A currently-tracking (possibly minimized) drive's `LiveTrackingView` holds
                        // this exact `Vehicle` model object as `selectedVehicle` — deleting it out
                        // from under an in-progress drive left `TripSummaryView`/`saveTrip` reading
                        // `vehicle?.name`/`.avgMpg` off an invalidated SwiftData model when the drive
                        // was finished (crash, or a trip saved with garbage/missing vehicle & MPG).
                        // Skip it here, same as a swipe landing on a built-in payer group is already
                        // a no-op above, rather than let the swipe silently do the wrong thing.
                        if let i = indexSet.first, !vehicleInUseByActiveDrive(vehicles[i]) {
                            pendingVehicleDelete = vehicles[i]
                        } else {
                            Haptics.warning()
                        }
                    }

                    Button {
                        // Same fix as the payer-group form's Cancel above — abandoned input used to
                        // stick around in `@State` and silently pre-fill the NEXT vehicle added in
                        // this Settings session.
                        if showingVehicleForm {
                            vehicleName = ""; vehicleMake = ""; vehicleModel = ""
                            vehicleYear = ""; vehicleTank = ""; vehicleMpg = ""
                        }
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
                        if duplicateVehicleName {
                            Text("A car with that name already exists.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Button("Save Vehicle") {
                            // A `0`/negative MPG isn't `nil`, so it would slip past every `?? 25`
                            // fallback elsewhere that only guards a genuinely-missing value — see
                            // `EditVehicleView.save()`'s doc comment for the concrete fallout.
                            let parsedMpg = Double(vehicleMpg)
                            let v = Vehicle(
                                name: vehicleName.trimmingCharacters(in: .whitespaces),
                                make: vehicleMake.isEmpty ? nil : vehicleMake,
                                model: vehicleModel.isEmpty ? nil : vehicleModel,
                                year: Int(vehicleYear),
                                tankSize: Double(vehicleTank),
                                avgMpg: (parsedMpg ?? 0) > 0 ? parsedMpg : nil
                            )
                            modelContext.insert(v)
                            try? modelContext.save()
                            Haptics.success()
                            vehicleName = ""; vehicleMake = ""; vehicleModel = ""
                            vehicleYear = ""; vehicleTank = ""; vehicleMpg = ""
                            showingVehicleForm = false
                        }
                        // `vehicleName.isEmpty` alone accepted whitespace-only input, AND nothing
                        // stopped two cars sharing a name — `Vehicle.name` has no uniqueness
                        // constraint but IS the join key every vehicle `Picker` tags by and every
                        // by-name lookup (`vehicles.first(where: { $0.name == … })`) resolves through.
                        // Two "Civic"s make every picker show two identically-tagged, indistinguishable
                        // rows, and any by-name lookup (fill-up tracking, a schedule's saved vehicle,
                        // `updateTripsForVehicle`'s rename) picks between them arbitrarily.
                        .disabled(vehicleName.trimmingCharacters(in: .whitespaces).isEmpty || duplicateVehicleName)
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

    /// Whether `v` is the vehicle a currently-tracking (or minimized) drive is recording with —
    /// see the `onDelete` guard above.
    private func vehicleInUseByActiveDrive(_ v: Vehicle) -> Bool {
        activeDrive.hasActiveDrive && activeDrive.tracker?.plannedVehicleName == v.name
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
    @Query private var scheduledDrives: [ScheduledDrive]
    @Query private var vehicles: [Vehicle]

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
        // `%.0f` rounded a fractional value (the add-vehicle form's own `.decimalPad` field allows
        // one, e.g. 32.5 MPG) — reopening this screen and tapping Save with no edits at all silently
        // wrote the ROUNDED value back, permanently perturbing the car's stored MPG/tank size (and,
        // via `updateTripsForVehicle`, every past trip's fuel estimate) on a pure no-op visit.
        // `.fractionLength(0...2)` formats losslessly for a value that has no fraction, and up to 2
        // decimal places for one that does.
        _tank = State(initialValue: vehicle.tankSize.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "")
        _mpg = State(initialValue: vehicle.avgMpg.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "")
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
            if duplicateVehicleName {
                Text("A car with that name already exists.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .navigationTitle(vehicle.name)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
        .toolbar {
            // Same reasoning as "Add Vehicle" in `SettingsView` — untrimmed input let a
            // whitespace-only nickname through, and nothing stopped renaming onto an EXISTING car's
            // name (worse than the add-form case: `updateTripsForVehicle`'s by-name predicate would
            // then re-point and re-fuel the OTHER car's whole trip history too, since both share a
            // name from that point on).
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || duplicateVehicleName)
            }
        }
    }

    /// Whether the edited name matches a DIFFERENT existing car (case-insensitively) — excludes
    /// `vehicle` itself so leaving the name unchanged (or just correcting its case) is never flagged.
    private var duplicateVehicleName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return vehicles.contains { $0.persistentModelID != vehicle.persistentModelID
            && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func save() {
        let oldName = vehicle.name
        let oldMpg = vehicle.avgMpg
        let newName = name.trimmingCharacters(in: .whitespaces)
        vehicle.name = newName.isEmpty ? name : newName
        vehicle.make = make.isEmpty ? nil : make
        vehicle.model = model.isEmpty ? nil : model
        vehicle.year = Int(year)
        vehicle.tankSize = Double(tank)
        // A `0` (or negative) MPG isn't `nil`, so it slipped past every `?? 25` fallback that only
        // guards against a genuinely-missing value — `TripDetailView`'s flat-average estimate divided
        // by it (→ "inf gal"), `RoutePredictView`/`LogMissedDriveView`'s estimates silently used
        // `FuelModel.mpg`'s `max(1, …)` floor of 1 MPG (a 30 mi route "costing" 30 gallons), and
        // `TripStore.save`/`FuelModel.gallons`'s own `guard ratedMpg > 0` made every trip in this car
        // record exactly 0 gallons — contributing $0 to every "Who's paying" total forever.
        let parsedMpg = Double(mpg)
        vehicle.avgMpg = (parsedMpg ?? 0) > 0 ? parsedMpg : nil
        try? context.save()
        // Retroactively re-point + recompute fuel for this car's past trips — but only when the
        // name or MPG actually changed. This used to run unconditionally on every Save (even one
        // that edited nothing but Make/Model/Year), silently re-rounding every past trip's fuel
        // estimate to whatever `%.0f`-truncated string this screen happened to be showing.
        if oldName != vehicle.name || oldMpg != vehicle.avgMpg {
            TripStore.updateTripsForVehicle(oldName: oldName, newName: vehicle.name,
                                            newMpg: vehicle.avgMpg, context: context)
        }
        // The vehicle name is the join key `ScheduledDrive.vehicleName` also stores (there's no
        // stable id link) — renaming here without repointing those left every schedule that used to
        // reference this car pointing at a name nothing resolves to. `LiveTrackingView.setup()`
        // then fell back to `vehicles.first`, silently starting that scheduled drive with whatever
        // OTHER car happened to be first — a wrong vehicle, wrong MPG, wrong fuel estimate.
        if oldName != vehicle.name {
            for drive in scheduledDrives where drive.vehicleName == oldName {
                drive.vehicleName = vehicle.name
            }
            try? context.save()
        }
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
