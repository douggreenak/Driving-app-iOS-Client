import SwiftUI
import SwiftData
import MapKit
import Charts

/// Trip detail laid out like the Alaska Airlines flight-status screen:
/// a map up top, a schedule/timeline card (scheduled vs. actual + delay) below it, then cards
/// for vehicle, the trip stats, speed-aware fuel, and a speed-over-time chart.
struct TripDetailView: View {
    @Bindable var trip: DriveTrip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var schedules: [ScheduledDrive]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @State private var showPlayback = false
    @State private var showEditSchedule = false
    @State private var showDeleteConfirm = false
    @State private var showAddStop = false
    /// Heavy track-derived values (polyline decode, fuel model, chart, region) computed once
    /// per trip instead of on every re-render (e.g. when the favorite star is toggled).
    @State private var derived: TripDerived?

    var body: some View {
        ScrollView {
            if let derived {
                content(derived)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .background(.black)
        .navigationTitle(trip.name ?? "Trip Detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.tap()
                    trip.isFavorite.toggle()
                    try? context.save()
                } label: {
                    Image(systemName: trip.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(trip.isFavorite ? .yellow : .secondary)
                }
                .accessibilityLabel(trip.isFavorite ? "Remove from favorites" : "Add to favorites")
            }
        }
        .task(id: trip.persistentModelID) { derived = TripDerived(trip: trip) }
        .fullScreenCover(isPresented: $showPlayback) {
            NavigationStack { RoutePlaybackView(trip: trip) }
        }
        .sheet(isPresented: $showEditSchedule) {
            EditTripScheduleView(trip: trip)
        }
        .confirmationDialog("Delete this trip?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Trip", role: .destructive) { deleteTrip() }
        } message: {
            Text("This permanently removes the recorded drive and all of its data — the track, fuel entries, and the synced copy.")
        }
    }

    @ViewBuilder
    private func content(_ d: TripDerived) -> some View {
        VStack(spacing: 0) {
            mapHeader(d)
            VStack(spacing: 16) {
                StatusBanner(status: .forTrip(delaySeconds: trip.delaySeconds))
                scheduleCard
                statsRow
                stopsCard
                if trip.usedRouteMatching { matchCard }
                vehicleCard
                paidByCard
                scheduleLinkCard
                fuelCard(d)
                if !d.chart.isEmpty { speedChartCard(d) }
                playButton(d)
                deleteButton
            }
            .padding()
        }
    }

    /// Editable stops for a driven trip (multi-stop annotation): add the places you stopped along
    /// the way; they show as numbered pins on the map above.
    private var stopsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Stops", systemImage: "mappin.and.ellipse").font(.headline)
                Spacer()
                Button { showAddStop = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.blue)
                }
            }
            if trip.stops.isEmpty {
                Text("No stops yet. Add the places you stopped along this drive.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(trip.stops.enumerated()), id: \.element.id) { i, stop in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(.orange, in: .circle)
                        Text(stop.address.isEmpty ? "Dropped pin" : stop.address)
                            .font(.subheadline).lineLimit(1)
                        Spacer()
                        Button { removeStop(stop) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(Color(.systemGray6), in: .rect(cornerRadius: 16))
        .sheet(isPresented: $showAddStop) {
            LocationSearchSheet(title: "Add Stop") { picked in
                trip.stops.append(RouteStop(address: picked.address, coordinate: picked.coordinate))
                try? context.save()
                Task { await TripStore.syncStops(for: trip) }
            }
        }
    }

    private func removeStop(_ stop: RouteStop) {
        trip.stops.removeAll { $0.id == stop.id }
        try? context.save()
        Task { await TripStore.syncStops(for: trip) }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Haptics.tap()
            showDeleteConfirm = true
        } label: {
            Label("Delete Trip", systemImage: "trash")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color(.systemGray6), in: .capsule)
        }
        .padding(.top, 4)
    }

    /// Remove the trip everywhere: the synced copy on the backend, then the local record — whose
    /// cascade rules also delete its track points and fuel entries — and return to the list.
    private func deleteTrip() {
        Haptics.warning()
        if let remoteID = trip.remoteID {
            Task { try? await APIClient.deleteTrip(id: remoteID) }
        }
        context.delete(trip)
        try? context.save()
        dismiss()
    }

    // MARK: - Map header

    /// Start dot reflects the *departure*: green when on time or unscheduled, orange when the
    /// departure was late. End dot reflects the *arrival*. Never red — that would imply a problem.
    private var startTint: Color {
        guard let d = trip.departureDelaySeconds else { return .green }
        // Orange whenever tracking started after the scheduled departure (small grace for jitter).
        return d >= 60 ? .statusDelay : .green
    }
    private var endTint: Color {
        guard let d = trip.delaySeconds else { return .green }
        return d >= 60 ? .statusDelay : .green
    }

    // Prefer a saved-place label ("Home") over the raw street address when one is bookmarked nearby.
    private var startName: String {
        PlaceNamer.name(for: trip.startCoordinate, fallback: trip.startAddress, in: savedPlaces)
    }
    private var endName: String {
        PlaceNamer.name(for: trip.endCoordinate, fallback: trip.endAddress, in: savedPlaces)
    }

    private func mapHeader(_ d: TripDerived) -> some View {
        ZStack(alignment: .bottom) {
            TripRouteMap(coordinates: d.displayCoords, deviations: d.deviationCoords,
                         region: d.region, start: trip.startCoordinate, end: trip.endCoordinate,
                         startColor: startTint, endColor: endTint, stops: trip.stops)
                .frame(height: 280)

            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false)

            HStack {
                endpointLabel(title: startName, time: trip.date, tint: startTint, align: .leading)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                endpointLabel(title: endName, time: trip.endDate, tint: endTint, align: .trailing)
            }
            .padding()
        }
    }

    private func endpointLabel(title: String, time: Date, tint: Color, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .multilineTextAlignment(align == .leading ? .leading : .trailing)
            Text(time, format: .dateTime.hour().minute())
                .font(.subheadline)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
        // Keep the labels legible over busy map tiles / POI labels.
        .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
    }

    // MARK: - Schedule / status card (the flight-status look)

    private var scheduleCard: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Schedule", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top) {
                timeColumn(label: "DEPARTED", time: trip.date, scheduled: trip.scheduledDeparture,
                           sub: startName, tint: startTint, align: .leading)
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "car.fill")
                        .foregroundStyle(.blue)
                    Text(durationString(trip.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                timeColumn(label: "ARRIVED", time: trip.endDate, scheduled: trip.scheduledArrival,
                           sub: endName, tint: endTint, align: .trailing)
            }

            // Departure → arrival progress line
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                    Capsule().fill(.blue).frame(width: geo.size.width, height: 4)
                    Circle().fill(startTint).frame(width: 10, height: 10)
                    Circle().fill(endTint).frame(width: 10, height: 10)
                        .offset(x: geo.size.width - 10)
                }
            }
            .frame(height: 12)

            if trip.scheduledDeparture != nil || trip.scheduledArrival != nil {
                HStack {
                    if let dep = trip.departureDelaySeconds {
                        delaySummary("Departed", dep, startTint, .leading)
                    }
                    Spacer()
                    if let arr = trip.delaySeconds {
                        delaySummary("Arrived", arr, endTint, .trailing)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    /// Show the actual time prominently; whenever a scheduled time exists, show it beneath —
    /// struck-through in the status tint when it differs, plain/secondary when it matches.
    private func timeColumn(label: String, time: Date, scheduled: Date?, sub: String, tint: Color, align: HorizontalAlignment) -> some View {
        let differs = scheduled.map { abs($0.timeIntervalSince(time)) >= 60 } ?? false
        return VStack(alignment: align, spacing: 3) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(time, format: .dateTime.hour().minute())
                .font(.system(.title2, design: .rounded, weight: .bold))
            if let scheduled {
                HStack(spacing: 3) {
                    Text("Sched").font(.caption2.weight(.semibold))
                    Text(scheduled, format: .dateTime.hour().minute()).strikethrough(differs)
                }
                .font(.caption2)
                .foregroundStyle(differs ? tint : .secondary)
            }
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    private func delaySummary(_ verb: String, _ seconds: Int, _ tint: Color, _ align: HorizontalAlignment) -> some View {
        let m = abs(seconds) / 60
        let text: String
        if abs(seconds) < 60 { text = "\(verb) on time" }
        else { text = "\(verb) \(m)m \(seconds > 0 ? "late" : "early")" }
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(abs(seconds) < 60 ? .green : tint)
            .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    // MARK: - Stats

    private var statsRow: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            stat("Distance", String(format: "%.1f mi", trip.distance), "point.topleft.down.to.point.bottomright.curvepath.fill", .blue)
            stat("Duration", durationString(trip.duration), "clock.fill", .orange)
            stat("Avg Speed", String(format: "%.0f mph", trip.avgSpeed), "speedometer", .green)
            stat("Top Speed", String(format: "%.0f mph", trip.maxSpeed), "gauge.with.dots.needle.67percent", .red)
        }
    }

    private func stat(_ label: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(.title3, design: .rounded, weight: .bold))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Map-matching card

    private var matchCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.filled.down.to.point.bottomright.curvepath")
                .font(.title3).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Snapped to roads").font(.subheadline.weight(.medium))
                Text("\(Int(trip.matchedFraction * 100))% on known roads · detours kept as recorded")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Vehicle

    private var vehicleCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.fill").font(.title2).foregroundStyle(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.vehicleName ?? "Vehicle").font(.subheadline.weight(.semibold))
                Label(trip.category.label, systemImage: trip.category.icon)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let mpg = trip.vehicleMpg {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f MPG", mpg)).font(.subheadline.weight(.semibold))
                    Text("rated").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Paid by (the core: who covers this drive)

    private var paidByCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.title2).foregroundStyle(trip.paidBy.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paid by").font(.subheadline.weight(.semibold))
                Text("Who covers this drive's gas").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(PaidBy.allCases, id: \.self) { p in
                    Button { trip.paidBy = p; try? context.save() } label: {
                        Label(p.label, systemImage: p.icon)
                    }
                }
            } label: {
                PayerChip(payer: trip.paidBy)
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Schedule link (retroactively apply a schedule)

    private var scheduleLinkCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2).foregroundStyle(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Schedule").font(.subheadline.weight(.semibold))
                Text(trip.scheduledArrival == nil
                     ? "Not linked — apply a schedule to grade on-time"
                     : "Graded against a scheduled arrival")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Menu {
                Button { showEditSchedule = true } label: {
                    Label("Edit times…", systemImage: "pencil")
                }
                if !schedules.isEmpty {
                    Section("Apply a saved schedule") {
                        ForEach(schedules) { s in
                            Button { apply(s) } label: { Label(s.title, systemImage: s.category.icon) }
                        }
                    }
                }
                if trip.scheduledArrival != nil || trip.scheduledDeparture != nil {
                    Button(role: .destructive) {
                        trip.scheduledArrival = nil
                        trip.scheduledDeparture = nil
                        try? context.save()
                    } label: { Label("Remove schedule", systemImage: "xmark.circle") }
                }
            } label: {
                Text(trip.scheduledArrival == nil ? "Apply" : "Change")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.blue.gradient, in: .capsule)
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    /// Apply a scheduled drive's arrival target to this past trip so it's graded on-time/delayed,
    /// using the schedule's arrival time-of-day on the day this trip happened.
    private func apply(_ schedule: ScheduledDrive) {
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: schedule.scheduledArrival)
        if let arrival = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: trip.date) {
            trip.scheduledArrival = arrival
        }
        let d = cal.dateComponents([.hour, .minute], from: schedule.departure)
        if let departure = cal.date(bySettingHour: d.hour ?? 0, minute: d.minute ?? 0, second: 0, of: trip.date) {
            trip.scheduledDeparture = departure
        }
        trip.name = schedule.title
        trip.category = schedule.category
        trip.paidBy = schedule.paidBy
        try? context.save()
    }

    // MARK: - Fuel (speed-aware)

    private func fuelCard(_ d: TripDerived) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "fuelpump.fill").foregroundStyle(.orange)
                Text("Fuel Used").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f gal", trip.estimatedGallons))
                    .font(.system(.title3, design: .rounded, weight: .bold))
            }
            Text("Estimated per-segment from the MPG your car gets at each speed — not a flat average.")
                .font(.caption2).foregroundStyle(.secondary)

            ForEach(d.bands) { band in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(band.label).font(.caption)
                        Spacer()
                        Text(String(format: "%.2f gal · %.1f mi", band.gallons, band.miles))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill(.orange.opacity(0.85))
                            .frame(width: max(4, geo.size.width * band.gallons / d.maxBandGallons), height: 6)
                    }
                    .frame(height: 6)
                }
            }

            Divider()
            HStack {
                Text("Flat-average estimate").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f gal", d.flatEstimate)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    // MARK: - Speed chart

    private func speedChartCard(_ d: TripDerived) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speed over time", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
            Chart(d.chart) { p in
                AreaMark(x: .value("min", p.min), y: .value("mph", p.mph))
                    .foregroundStyle(.linearGradient(colors: [.green.opacity(0.5), .green.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("min", p.min), y: .value("mph", p.mph))
                    .foregroundStyle(.green)
                    .interpolationMethod(.monotone)
            }
            .chartXAxisLabel("minutes")
            .chartYAxisLabel("mph")
            .frame(height: 150)
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private func playButton(_ d: TripDerived) -> some View {
        Button {
            showPlayback = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill").font(.title3)
                Text("Play route").font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.blue.gradient, in: .capsule)
        }
        .disabled(d.chart.count < 2)
    }

    private func durationString(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }
}

/// Pre-computed, render-stable view of a trip's track. Built once via `.task`.
struct TripDerived {
    struct ChartPoint: Identifiable { let id: Int; let min: Double; let mph: Double }

    let displayCoords: [CLLocationCoordinate2D]
    let deviationCoords: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion
    let bands: [FuelModel.Band]
    let maxBandGallons: Double
    let flatEstimate: Double
    let chart: [ChartPoint]

    init(trip: DriveTrip) {
        let pts = trip.orderedPoints
        let recorded = pts.map {
            RecordedPoint(t: $0.t, coordinate: $0.coordinate, speed: $0.speed, course: $0.course, accuracy: $0.accuracy)
        }
        let segments = FuelModel.segments(from: recorded)
        let rated = trip.vehicleMpg ?? 25
        bands = FuelModel.bandBreakdown(segments: segments, ratedMpg: rated)
        maxBandGallons = max(0.0001, bands.map(\.gallons).max() ?? 0.0001)
        flatEstimate = trip.distance / rated

        let coords = trip.displayCoordinates
        displayCoords = coords
        deviationCoords = pts.filter { !$0.onRoad }.map(\.coordinate)
        region = .enclosing(coords.isEmpty ? [trip.startCoordinate, trip.endCoordinate] : coords)

        let start = pts.first?.t ?? trip.date
        chart = pts.enumerated().map {
            ChartPoint(id: $0.offset, min: $0.element.t.timeIntervalSince(start) / 60, mph: $0.element.speed)
        }
    }
}

/// Edit a completed trip's schedule after the fact: its name and the scheduled departure/arrival
/// times it should be graded against (on-time / late). Either time can be cleared.
struct EditTripScheduleView: View {
    @Bindable var trip: DriveTrip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hasDeparture: Bool
    @State private var hasArrival: Bool
    @State private var departure: Date
    @State private var arrival: Date

    init(trip: DriveTrip) {
        self.trip = trip
        _name = State(initialValue: trip.name ?? "")
        _hasDeparture = State(initialValue: trip.scheduledDeparture != nil)
        _hasArrival = State(initialValue: trip.scheduledArrival != nil)
        _departure = State(initialValue: trip.scheduledDeparture ?? trip.date)
        _arrival = State(initialValue: trip.scheduledArrival ?? trip.endDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Name (e.g. Morning Commute)", text: $name)
                }
                Section {
                    Toggle("Scheduled departure", isOn: $hasDeparture.animation())
                    if hasDeparture {
                        DatePicker("Departs", selection: $departure)
                        labeledDelta("Actual departure", trip.date, departure)
                    }
                } footer: {
                    Text("Set the time you were supposed to leave. The start dot turns orange if you left late.")
                }
                Section {
                    Toggle("Scheduled arrival", isOn: $hasArrival.animation())
                    if hasArrival {
                        DatePicker("Arrives", selection: $arrival)
                        labeledDelta("Actual arrival", trip.endDate, arrival)
                    }
                } footer: {
                    Text("Set the time you were supposed to arrive. The trip is graded on-time or late against this.")
                }
            }
            .navigationTitle("Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() } }
            }
        }
    }

    /// Shows the actual time and the resulting delay vs. the chosen scheduled time.
    private func labeledDelta(_ label: String, _ actual: Date, _ scheduled: Date) -> some View {
        let secs = Int(actual.timeIntervalSince(scheduled))
        let m = abs(secs) / 60
        let text = abs(secs) < 60 ? "on time" : "\(m)m \(secs > 0 ? "late" : "early")"
        return HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(actual, format: .dateTime.hour().minute())
            Text("(\(text))").foregroundStyle(abs(secs) < 60 ? .green : (secs > 0 ? .statusDelay : .blue))
        }
        .font(.caption)
    }

    private func save() {
        trip.name = name.isEmpty ? nil : name
        trip.scheduledDeparture = hasDeparture ? departure : nil
        trip.scheduledArrival = hasArrival ? arrival : nil
        try? context.save()
        dismiss()
    }
}

/// Static map of a recorded trip from pre-computed coordinates (no per-render decoding).
struct TripRouteMap: View {
    let coordinates: [CLLocationCoordinate2D]
    let deviations: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    var startColor: Color = .green
    var endColor: Color = .red
    var stops: [RouteStop] = []

    var body: some View {
        Map(initialPosition: .region(region)) {
            if coordinates.count >= 2 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            // Mark recorded deviations (points kept off the matched road) in orange.
            ForEach(deviations.indices, id: \.self) { i in
                MapCircle(center: deviations[i], radius: 18)
                    .foregroundStyle(.orange.opacity(0.7))
            }
            Annotation("Start", coordinate: start) { pin(startColor) }
            ForEach(Array(stops.enumerated()), id: \.element.id) { i, stop in
                Annotation("Stop \(i + 1)", coordinate: stop.coordinate) { stopPin(i + 1) }
            }
            Annotation("End", coordinate: end) { pin(endColor) }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func pin(_ color: Color) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 16, height: 16)
            Circle().stroke(.white, lineWidth: 2).frame(width: 16, height: 16)
        }
    }

    private func stopPin(_ number: Int) -> some View {
        Text("\(number)")
            .font(.caption2.weight(.bold)).foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(.orange, in: .circle)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}

extension MKCoordinateRegion {
    /// A region that encloses all coordinates with a little padding.
    static func enclosing(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return .init(center: .init(latitude: 0, longitude: 0),
                         span: .init(latitudeDelta: 1, longitudeDelta: 1))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (maxLat - minLat) * 1.4),
                                    longitudeDelta: max(0.005, (maxLng - minLng) * 1.4))
        return .init(center: center, span: span)
    }
}
