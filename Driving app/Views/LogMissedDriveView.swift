import SwiftUI
import SwiftData
import MapKit

/// "Log a Missed Drive" — record a trip that already happened but was never GPS-tracked (forgot to
/// hit record, or it was driven before this device started tracking). Mirrors `RoutePredictView`'s
/// route-lookup UX (pick a start/destination, MapKit estimates the road distance) but instead of a
/// throwaway estimate, this actually saves a `DriveTrip` — using the *entered* departure/arrival for
/// timing rather than MapKit's predicted travel time, since the whole point is recording what really
/// happened. Optionally pick one of your scheduled drives to prefill the route and mark that
/// occurrence as done, instead of typing everything from scratch.
///
/// Saved trips are flagged `isManualEntry` and show a clear "not a recorded drive" notice everywhere
/// they appear (`TripsListView`, `TripDetailView`) — see those files' manual-entry handling.
struct LogMissedDriveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var vehicles: [Vehicle]
    @Query private var settingsList: [UserSettings]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]
    @Query(sort: \ScheduledDrive.createdAt, order: .reverse) private var schedules: [ScheduledDrive]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]

    @State private var selectedSchedule: ScheduledDrive?
    @State private var showScheduleList = false

    @State private var name = ""
    @State private var startAddress = ""
    @State private var endAddress = ""
    @State private var startCoord: CLLocationCoordinate2D?
    @State private var endCoord: CLLocationCoordinate2D?

    @State private var departure = Date.now.addingTimeInterval(-3600)
    @State private var arrival = Date.now

    @State private var category: TripCategory = .other
    @State private var paidBy: String = PayerGroup.selfKey
    @State private var vehicleName: String?
    @State private var notes = ""

    @State private var routeMiles: Double?
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var calculating = false
    @State private var routeError: String?
    @State private var saving = false
    @State private var didPrefillPayer = false

    private var fuelPrice: Double { settingsList.first?.fuelPricePerGallon ?? 3.75 }
    private var ratedMpg: Double {
        if let named = vehicles.first(where: { $0.name == vehicleName })?.avgMpg { return named }
        return vehicles.first?.avgMpg ?? 25
    }

    private var elapsedSeconds: Int { max(0, Int(arrival.timeIntervalSince(departure))) }
    private var avgMph: Double { elapsedSeconds > 0 ? (routeMiles ?? 0) / (Double(elapsedSeconds) / 3600) : 0 }
    private var estimatedGallons: Double {
        guard let miles = routeMiles, miles > 0 else { return 0 }
        return miles / FuelModel.mpg(atMph: avgMph, ratedMpg: ratedMpg)
    }

    private var arrivalIsValid: Bool { arrival > departure }
    private var canLog: Bool {
        startCoord != nil && endCoord != nil && routeMiles != nil && arrivalIsValid && !calculating && !saving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    intro
                    scheduleCard
                    if selectedSchedule == nil { manualRouteCard }
                    timingCard
                    if let routeError {
                        Label(routeError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !arrivalIsValid {
                        Label("Arrival must be after departure.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if routeMiles != nil { estimateCard }
                    detailsCard
                    logButton
                }
                .padding()
            }
            .background(.black)
            .navigationTitle("Log a Missed Drive")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                // Mirrors the big "Log Drive" button below — always reachable without scrolling
                // a long form, matching `NewScheduledDriveView`'s toolbar save action.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") { Task { await logDrive() } }.disabled(!canLog)
                }
            }
            .onAppear {
                guard !didPrefillPayer else { return }
                didPrefillPayer = true
                paidBy = settingsList.first?.defaultPaidByRaw ?? PayerGroup.selfKey
            }
        }
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Forgot to hit record?", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
            Text("Log the drive after the fact. Pick a start and destination (or one of your scheduled drives) and when it actually happened — this is estimated from a map route, not a GPS track, and is clearly marked as such wherever it shows up.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Scheduled drive (optional)

    @ViewBuilder
    private var scheduleCard: some View {
        if let s = selectedSchedule {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Scheduled Drive", systemImage: "calendar").font(.headline)
                    Spacer()
                    Button {
                        Haptics.tap()
                        selectedSchedule = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Image(systemName: s.category.icon).font(.subheadline).foregroundStyle(.blue)
                    Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: "airplane.departure").font(.caption2).foregroundStyle(.green)
                    Text(placeName(s.startCoordinate, s.startAddress)).font(.caption).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "airplane.arrival").font(.caption2).foregroundStyle(.red)
                    Text(placeName(s.endCoordinate, s.endAddress)).font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
        } else if !schedules.isEmpty {
            Button {
                Haptics.tap()
                showScheduleList = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock").font(.title3).foregroundStyle(.blue).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pick a scheduled drive").font(.subheadline.weight(.semibold))
                        Text("Prefills the route and marks it as done").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.systemGray6), in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showScheduleList) { scheduleListSheet }
        }
    }

    private var scheduleListSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(schedules) { s in
                        Button { pick(s) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: s.category.icon).font(.subheadline).foregroundStyle(.blue)
                                    Text(s.title).font(.headline).lineLimit(1)
                                    Spacer()
                                    PayerChip(PayerGroup.resolve(key: s.paidByRaw, in: payerGroups))
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: "airplane.departure").font(.caption2).foregroundStyle(.green)
                                    Text(placeName(s.startCoordinate, s.startAddress)).font(.caption).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: "airplane.arrival").font(.caption2).foregroundStyle(.red)
                                    Text(placeName(s.endCoordinate, s.endAddress)).font(.caption).lineLimit(1)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(.black)
            .navigationTitle("Pick a Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScheduleList = false } }
            }
        }
    }

    /// Prefill the route and details from a picked schedule; default the timing to that schedule's
    /// most recent occurrence (still freely editable below — this is only a starting guess).
    private func pick(_ s: ScheduledDrive) {
        Haptics.success()
        selectedSchedule = s
        showScheduleList = false
        name = s.title
        startAddress = s.startAddress; startCoord = s.startCoordinate
        endAddress = s.endAddress; endCoord = s.endCoordinate
        category = s.category
        paidBy = s.paidByRaw
        vehicleName = s.vehicleName
        // Default to the nearest occurrence's time-of-day, clamped to the past (a missed drive
        // can't be in the future) — the DatePickers below are freely editable if it was a
        // different day.
        let dep = s.statusReferenceDeparture()
        departure = min(dep, .now)
        arrival = departure.addingTimeInterval(max(60, s.arrivalBudget))
        routeMiles = nil; routeCoordinates = []; routeError = nil
        Task { await recalcRoute() }
    }

    // MARK: - Manual route

    private var manualRouteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.headline)
            AddressPickerRow(title: "Start", systemImage: "flag.fill",
                             address: $startAddress, coordinate: $startCoord) {
                Task { await recalcRoute() }
            }
            AddressPickerRow(title: "Destination", systemImage: "mappin",
                             address: $endAddress, coordinate: $endCoord) {
                Task { await recalcRoute() }
            }
            if calculating {
                HStack { ProgressView(); Text("Looking up the route…").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Timing

    private var timingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("When it happened", systemImage: "clock").font(.headline)
            DatePicker("Left at", selection: $departure)
            DatePicker("Arrived at", selection: $arrival)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Estimate

    private var estimateCard: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Estimated from a map route", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            HStack(spacing: 0) {
                metric(String(format: "%.1f", routeMiles ?? 0), "miles")
                Divider().frame(height: 34)
                metric(timeString(elapsedSeconds), "elapsed")
                Divider().frame(height: 34)
                metric(String(format: "%.2f", estimatedGallons), "gallons")
            }
            Text("At \(Int(ratedMpg)) MPG and an average \(Int(avgMph)) mph over the time you entered — not measured from a recorded track.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.25), lineWidth: 1))
    }

    private func metric(_ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).fontDesign(.rounded)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Details", systemImage: "list.bullet").font(.headline)
            if selectedSchedule == nil {
                TextField("Trip name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Paid by", selection: $paidBy) {
                ForEach(payerGroups.filter { !$0.isArchived }) { group in
                    Label(group.name, systemImage: group.icon).tag(group.key)
                }
            }
            Picker("Category", selection: $category) {
                ForEach(TripCategory.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            if !vehicles.isEmpty {
                Picker("Vehicle", selection: $vehicleName) {
                    Text("None").tag(String?.none)
                    ForEach(vehicles) { v in Text(v.name).tag(String?.some(v.name)) }
                }
            }
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(2)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Log

    private var logButton: some View {
        Button(action: { Task { await logDrive() } }) {
            HStack(spacing: 10) {
                if saving { ProgressView().tint(.white) }
                Text(saving ? "Logging…" : "Log Drive").font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background((canLog ? Color.orange : Color.gray).gradient, in: .capsule)
        }
        .disabled(!canLog)
    }

    private func recalcRoute() async {
        guard let s = startCoord, let e = endCoord else { return }
        calculating = true; routeError = nil; routeMiles = nil; routeCoordinates = []
        defer { calculating = false }
        guard let result = await RouteMatcher.multiLegRoute(through: [s, e]) else {
            routeError = "Couldn't find a driving route for these addresses. Check them and your connection."
            return
        }
        routeMiles = result.miles
        routeCoordinates = result.coordinates
    }

    private func logDrive() async {
        guard let s = startCoord, let e = endCoord, let miles = routeMiles, arrivalIsValid else { return }
        saving = true
        defer { saving = false }
        let input = TripStore.ManualInput(
            date: departure, endDate: arrival,
            startAddress: startAddress, endAddress: endAddress,
            startCoordinate: s, endCoordinate: e,
            distanceMiles: miles, routeCoordinates: routeCoordinates,
            category: category, paidBy: paidBy,
            notes: notes.isEmpty ? nil : notes,
            name: name.isEmpty ? nil : name,
            vehicleName: vehicleName,
            vehicleMpg: vehicles.first(where: { $0.name == vehicleName })?.avgMpg,
            scheduledDeparture: selectedSchedule != nil ? departure : nil,
            scheduledArrival: selectedSchedule != nil ? arrival : nil
        )
        guard await TripStore.saveManual(input, context: context) != nil else {
            routeError = "Couldn't save this drive. Double-check the times and try again."
            return
        }
        // Mark the picked occurrence as driven so it drops off the departures board instead of
        // continuing to read as missed/late.
        if let schedule = selectedSchedule {
            schedule.lastStartedAt = departure
            schedule.lastCompletedAt = arrival
            try? context.save()
            Task { await ScheduledDriveStore.sync(context: context) }
        }
        Haptics.success()
        dismiss()
    }

    private func placeName(_ coord: CLLocationCoordinate2D, _ fallback: String) -> String {
        PlaceNamer.name(for: coord, fallback: fallback, in: savedPlaces)
    }

    private func timeString(_ seconds: Int) -> String {
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }
}
