import SwiftUI
import MapKit
import Charts
import Combine

/// Flightradar24-style replay: the camera follows a heading-aware marker along the track while a
/// rich telemetry bar (speed, heading, distance, clock) and a live speed strip update underneath.
struct RoutePlaybackView: View {
    let trip: DriveTrip
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var index: Double = 0
    @State private var playing = false
    @State private var rate: Double = 8
    @State private var follow = true
    @State private var graphMetric: GraphMetric = .speed
    /// The telemetry panel is a native detented sheet (Apple-Maps style) — always presented while
    /// playback is open. Detents give smooth, interruptible drag-to-resize for free.
    @State private var showPanel = true
    @State private var selectedDetent: PresentationDetent = .height(188)
    @State private var cameraPosition: MapCameraPosition

    /// Collapsed: just readouts + scrubber + transport. Expanded: adds sub-telemetry + graph.
    private let collapsedDetent = PresentationDetent.height(188)
    private let expandedDetent = PresentationDetent.fraction(0.52)
    private var isExpanded: Bool { selectedDetent == expandedDetent }

    /// What the bottom chart plots.
    enum GraphMetric: String, CaseIterable, Identifiable {
        case speed, altitude
        var id: String { rawValue }
        var label: String { self == .speed ? "Speed" : "Altitude" }
        var unit: String { self == .speed ? "mph" : "ft" }
        var icon: String { self == .speed ? "speedometer" : "mountain.2.fill" }
        var color: Color { self == .speed ? .green : .purple }
        func value(_ s: SpeedSample) -> Double { self == .speed ? s.mph : s.alt }
    }

    private let points: [TrackPoint]
    private let cumulativeMiles: [Double]
    private let headings: [Double]
    private let samples: [SpeedSample]
    private let totalSeconds: Double
    /// 30 fps so the marker glides between recorded points instead of snapping to each one.
    private static let fps = 30.0
    private let timer = Timer.publish(every: 1.0 / fps, on: .main, in: .common).autoconnect()

    struct SpeedSample: Identifiable { let id: Int; let t: Double; let mph: Double; let alt: Double }

    init(trip: DriveTrip) {
        self.trip = trip
        let pts = trip.orderedPoints
        self.points = pts

        var cum: [Double] = pts.isEmpty ? [] : [0]
        for i in 1..<max(pts.count, 1) where i < pts.count {
            cum.append((cum.last ?? 0) + pts[i - 1].coordinate.distanceMeters(to: pts[i].coordinate) / 1609.34)
        }
        self.cumulativeMiles = cum

        var hs = [Double](repeating: 0, count: pts.count)
        for i in pts.indices {
            let a = pts[max(0, i - 1)].coordinate
            let b = pts[min(pts.count - 1, i + (i == 0 ? 1 : 0))].coordinate
            hs[i] = RoutePlaybackView.bearing(from: a, to: b)
        }
        self.headings = hs

        let start = pts.first?.t ?? trip.date
        self.samples = pts.enumerated().map { SpeedSample(id: $0.offset, t: $0.element.t.timeIntervalSince(start), mph: $0.element.speed, alt: $0.element.altitude) }
        self.totalSeconds = pts.last.map { $0.t.timeIntervalSince(start) } ?? 0

        let center = pts.first?.coordinate ?? trip.startCoordinate
        _cameraPosition = State(initialValue: .camera(MapCamera(centerCoordinate: center, distance: 2200, heading: 0, pitch: 0)))
    }

    private var i: Int { min(points.count - 1, max(0, Int(index))) }
    private var current: TrackPoint? { points.indices.contains(i) ? points[i] : nil }

    /// Fractional progress between point `i` and `i+1`, for smooth interpolation.
    private var frac: Double { index - floor(index) }

    /// Marker position interpolated between adjacent recorded points so motion is continuous.
    private var markerCoordinate: CLLocationCoordinate2D? {
        guard points.indices.contains(i) else { return nil }
        guard i + 1 < points.count else { return points[i].coordinate }
        let a = points[i].coordinate, b = points[i + 1].coordinate
        let f = frac
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                      longitude: a.longitude + (b.longitude - a.longitude) * f)
    }

    private var markerHeading: Double {
        let h0 = headings[safe: i] ?? 0
        guard i + 1 < headings.count else { return h0 }
        return Self.interpolateAngle(h0, headings[i + 1], frac)
    }

    /// Interpolated trip miles, for a continuously-updating distance readout.
    private var currentMiles: Double {
        let m0 = cumulativeMiles[safe: i] ?? 0
        guard i + 1 < cumulativeMiles.count else { return m0 }
        return m0 + (cumulativeMiles[i + 1] - m0) * frac
    }

    /// Interpolated speed, so the mph readout doesn't visibly step.
    private var currentSpeed: Double {
        let s0 = points[safe: i]?.speed ?? 0
        guard i + 1 < points.count else { return s0 }
        return s0 + (points[i + 1].speed - s0) * frac
    }

    var body: some View {
        map.ignoresSafeArea()
            .overlay(alignment: .topTrailing) { followButton }
            .navigationTitle("Route Playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onReceive(timer) { _ in tick() }
            .onChange(of: index) { _, _ in if follow { recenter() } }
            // Pause playback when the device locks or the app is backgrounded, so the marker
            // doesn't silently run to the end while the screen is off.
            .onChange(of: scenePhase) { _, phase in if phase != .active { playing = false } }
            .sheet(isPresented: $showPanel) {
                telemetryPanel
                    .presentationDetents([collapsedDetent, expandedDetent], selection: $selectedDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled)
                    .presentationBackground {
                        Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 38))
                    }
                    .interactiveDismissDisabled()
                    .presentationContentInteraction(.resizes)
            }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition) {
            if points.count >= 2 {
                let head = markerCoordinate ?? points[i].coordinate
                MapPolyline(coordinates: Array(points.prefix(i + 1)).map(\.coordinate) + [head])
                    .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: [head] + Array(points.suffix(from: min(i + 1, points.count - 1))).map(\.coordinate))
                    .stroke(.blue.opacity(0.22), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
            if let c = markerCoordinate {
                Annotation("", coordinate: c) { marker }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        // Hide the default MapKit controls (the scale bar in particular collided with the clock
        // and notch since the map ignores the safe area); distance is shown in the telemetry bar.
        .mapControls { }
    }

    private var marker: some View {
        ZStack {
            Circle().fill(.blue.opacity(0.2)).frame(width: 40, height: 40)
            Circle().fill(.white).frame(width: 28, height: 28).shadow(radius: 2)
            Image(systemName: "location.north.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.blue)
                .rotationEffect(.degrees(markerHeading))
        }
    }

    private var followButton: some View {
        Button {
            follow.toggle()
            if follow { recenter() }
            else { cameraPosition = .region(.enclosing(points.map(\.coordinate))) }
        } label: {
            Image(systemName: follow ? "location.fill" : "location")
                .font(.title3)
                .foregroundStyle(follow ? .white : .blue)
                .padding(12)
                .glassEffect(follow ? .regular.tint(.blue).interactive() : .regular.interactive(), in: .circle)
        }
        .padding(.trailing, 18)
        .padding(.top, 8)
    }

    // MARK: - Telemetry panel (native detented sheet)

    /// Content ordered so the essentials (readouts, scrubber, transport) show at the collapsed
    /// detent, and the sub-telemetry + graph are revealed as you drag the sheet up.
    private var telemetryPanel: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    bigReadout(String(format: "%.0f", currentSpeed), "mph", .green)
                    Divider().frame(height: 36)
                    bigReadout(headingText, "heading", .blue)
                    Divider().frame(height: 36)
                    bigReadout(String(format: "%.1f", currentMiles), "miles", .orange)
                    Divider().frame(height: 36)
                    bigReadout(clockString, "clock", .secondary)
                }

                if points.count > 1 {
                    Slider(value: $index, in: 0...Double(points.count - 1)) { editing in
                        if editing { playing = false }
                    }
                    .tint(.blue)
                }

                HStack(spacing: 28) {
                    Button { index = 0 } label: { Image(systemName: "backward.end.fill").font(.title3) }
                    Button {
                        if i >= points.count - 1 { index = 0 }
                        playing.toggle()
                    } label: {
                        Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 46))
                    }
                    rateMenu
                }
                .foregroundStyle(.blue)

                if isExpanded {
                    Divider()
                    subTelemetry
                    graphHeader
                    speedStrip
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var rateMenu: some View {
        // Speed picker — updates `rate` live, so playback speed changes mid-playback.
        Menu {
            ForEach([1.0, 2.0, 4.0, 8.0, 16.0, 32.0], id: \.self) { r in
                Button { rate = r } label: {
                    Label("\(Int(r))×", systemImage: rate == r ? "checkmark" : "")
                }
            }
        } label: {
            Text("\(Int(rate))×").font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                .frame(width: 44, height: 30)
                .glassEffect(.regular, in: .capsule)
        }
    }

    /// Dropdown to choose which metric the chart plots, plus the live value.
    private var graphHeader: some View {
        HStack {
            Menu {
                Picker("Graph", selection: $graphMetric.animation()) {
                    ForEach(GraphMetric.allCases) { m in
                        Label(m.label, systemImage: m.icon).tag(m)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: graphMetric.icon).font(.caption2)
                    Text(graphMetric.label).font(.caption.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(graphMetric.color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(graphMetric.color.opacity(0.12), in: .capsule)
            }
            Spacer()
            Text(String(format: "%.0f %@", graphMetric == .speed ? currentSpeed : (current?.altitude ?? 0), graphMetric.unit))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private var speedStrip: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("t", s.t), y: .value(graphMetric.label, graphMetric.value(s)))
                    .foregroundStyle(.linearGradient(colors: [graphMetric.color.opacity(0.45), graphMetric.color.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", s.t), y: .value(graphMetric.label, graphMetric.value(s)))
                    .foregroundStyle(graphMetric.color)
                    .interpolationMethod(.monotone)
            }
            if let c = current, let start = points.first?.t {
                RuleMark(x: .value("now", c.t.timeIntervalSince(start)))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 46)
    }

    private var subTelemetry: some View {
        HStack(spacing: 16) {
            subItem("mountain.2.fill", String(format: "%.0f ft", current?.altitude ?? 0), "altitude")
            subItem("location.north.line.fill", String(format: "%.0f°", headings[safe: i] ?? 0), "course")
            subItem("scope", String(format: "±%.0f m", current?.accuracy ?? 0), "accuracy")
        }
        .frame(maxWidth: .infinity)
    }

    private func subItem(_ icon: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.caption.weight(.semibold))
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private func bigReadout(_ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tint == .secondary ? .primary : tint)
            Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Logic

    private func tick() {
        guard playing, points.count > 1 else { return }
        index += rate / Self.fps
        if index >= Double(points.count - 1) {
            index = Double(points.count - 1)
            playing = false
        }
    }

    private func recenter() {
        guard let c = markerCoordinate else { return }
        cameraPosition = .camera(MapCamera(centerCoordinate: c, distance: 2200, heading: 0, pitch: 0))
    }

    private var headingText: String {
        let h = headings[safe: i] ?? 0
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return dirs[Int((h + 22.5) / 45) % 8]
    }

    private var clockString: String {
        guard let c = current else { return "--" }
        return c.t.formatted(.dateTime.hour().minute())
    }

    /// Shortest-path angular interpolation (handles the 360°→0° wraparound).
    static func interpolateAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var diff = (b - a).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return (a + diff * t + 360).truncatingRemainder(dividingBy: 360)
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
