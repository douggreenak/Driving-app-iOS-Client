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
    @State private var showPlayback = false
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
        .navigationTitle("Trip Detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    trip.isFavorite.toggle()
                    try? context.save()
                } label: {
                    Image(systemName: trip.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(trip.isFavorite ? .yellow : .secondary)
                }
            }
        }
        .task(id: trip.persistentModelID) { derived = TripDerived(trip: trip) }
        .fullScreenCover(isPresented: $showPlayback) {
            NavigationStack { RoutePlaybackView(trip: trip) }
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
                if trip.usedRouteMatching { matchCard }
                vehicleCard
                paidByCard
                fuelCard(d)
                if !d.chart.isEmpty { speedChartCard(d) }
                playButton(d)
            }
            .padding()
        }
    }

    // MARK: - Map header

    private func mapHeader(_ d: TripDerived) -> some View {
        ZStack(alignment: .bottom) {
            TripRouteMap(coordinates: d.displayCoords, deviations: d.deviationCoords,
                         region: d.region, start: trip.startCoordinate, end: trip.endCoordinate)
                .frame(height: 280)

            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false)

            HStack {
                endpointLabel(title: trip.startAddress, time: trip.date, tint: .green, align: .leading)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                endpointLabel(title: trip.endAddress, time: trip.endDate, tint: .red, align: .trailing)
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
                timeColumn(label: "DEPARTED", time: trip.date, sub: trip.startAddress, align: .leading)
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "car.fill")
                        .foregroundStyle(.blue)
                    Text(durationString(trip.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                timeColumn(label: "ARRIVED", time: trip.endDate, sub: trip.endAddress, align: .trailing)
            }

            // Departure → arrival progress line
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                    Capsule().fill(.blue).frame(width: geo.size.width, height: 4)
                    Circle().fill(.green).frame(width: 10, height: 10)
                    Circle().fill(.red).frame(width: 10, height: 10)
                        .offset(x: geo.size.width - 10)
                }
            }
            .frame(height: 12)

            if let scheduled = trip.scheduledArrival {
                HStack {
                    Text("Scheduled arrival")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(scheduled, format: .dateTime.hour().minute())
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private func timeColumn(label: String, time: Date, sub: String, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 3) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(time, format: .dateTime.hour().minute())
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
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

/// Static map of a recorded trip from pre-computed coordinates (no per-render decoding).
struct TripRouteMap: View {
    let coordinates: [CLLocationCoordinate2D]
    let deviations: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D

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
            Annotation("Start", coordinate: start) { pin(.green) }
            Annotation("End", coordinate: end) { pin(.red) }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func pin(_ color: Color) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 16, height: 16)
            Circle().stroke(.white, lineWidth: 2).frame(width: 16, height: 16)
        }
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
