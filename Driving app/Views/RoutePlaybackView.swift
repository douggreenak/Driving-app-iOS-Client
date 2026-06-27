import SwiftUI
import MapKit
import Charts
import Combine

/// Flightradar24-style replay: the camera follows a heading-aware marker along the track while a
/// rich telemetry bar (speed, heading, distance, clock) and a live speed strip update underneath.
struct RoutePlaybackView: View {
    let trip: DriveTrip
    @Environment(\.dismiss) private var dismiss

    @State private var index: Double = 0
    @State private var playing = false
    @State private var rate: Double = 8
    @State private var follow = true
    @State private var cameraPosition: MapCameraPosition

    private let points: [TrackPoint]
    private let cumulativeMiles: [Double]
    private let headings: [Double]
    private let samples: [SpeedSample]
    private let totalSeconds: Double
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    struct SpeedSample: Identifiable { let id: Int; let t: Double; let mph: Double }

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
        self.samples = pts.enumerated().map { SpeedSample(id: $0.offset, t: $0.element.t.timeIntervalSince(start), mph: $0.element.speed) }
        self.totalSeconds = pts.last.map { $0.t.timeIntervalSince(start) } ?? 0

        let center = pts.first?.coordinate ?? trip.startCoordinate
        _cameraPosition = State(initialValue: .camera(MapCamera(centerCoordinate: center, distance: 2200, heading: 0, pitch: 0)))
    }

    private var i: Int { min(points.count - 1, max(0, Int(index))) }
    private var current: TrackPoint? { points.indices.contains(i) ? points[i] : nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            map.ignoresSafeArea()
            followButton
            telemetry
        }
        .navigationTitle("Route Playback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .onReceive(timer) { _ in tick() }
        .onChange(of: index) { _, _ in if follow { recenter() } }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition) {
            if points.count >= 2 {
                MapPolyline(coordinates: Array(points.prefix(i + 1)).map(\.coordinate))
                    .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: Array(points.suffix(from: i)).map(\.coordinate))
                    .stroke(.blue.opacity(0.22), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
            if let c = current {
                Annotation("", coordinate: c.coordinate) { marker }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private var marker: some View {
        ZStack {
            Circle().fill(.blue.opacity(0.2)).frame(width: 40, height: 40)
            Circle().fill(.white).frame(width: 28, height: 28).shadow(radius: 2)
            Image(systemName: "location.north.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.blue)
                .rotationEffect(.degrees(headings[safe: i] ?? 0))
        }
    }

    private var followButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    follow.toggle()
                    if follow { recenter() }
                    else { cameraPosition = .region(.enclosing(points.map(\.coordinate))) }
                } label: {
                    Image(systemName: follow ? "location.fill" : "location")
                        .font(.title3)
                        .foregroundStyle(follow ? .white : .blue)
                        .padding(12)
                        .background(follow ? AnyShapeStyle(.blue) : AnyShapeStyle(.ultraThinMaterial), in: .circle)
                        .shadow(radius: 4, y: 2)
                }
                .padding(.trailing, 18)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Telemetry

    private var telemetry: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                bigReadout(String(format: "%.0f", current?.speed ?? 0), "mph", .green)
                Divider().frame(height: 40)
                bigReadout(headingText, "heading", .blue)
                Divider().frame(height: 40)
                bigReadout(String(format: "%.1f", cumulativeMiles[safe: i] ?? 0), "miles", .orange)
                Divider().frame(height: 40)
                bigReadout(clockString, "clock", .secondary)
            }

            subTelemetry

            speedStrip

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
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 52))
                }
                Menu {
                    ForEach([4.0, 8.0, 16.0, 32.0], id: \.self) { r in Button("\(Int(r))×") { rate = r } }
                } label: {
                    Text("\(Int(rate))×").font(.headline)
                        .frame(width: 46, height: 32)
                        .background(Color(.systemGray5), in: .capsule)
                }
            }
            .foregroundStyle(.blue)
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 22))
        .padding()
    }

    private var speedStrip: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("t", s.t), y: .value("mph", s.mph))
                    .foregroundStyle(.linearGradient(colors: [.green.opacity(0.45), .green.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", s.t), y: .value("mph", s.mph))
                    .foregroundStyle(.green)
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
        VStack(spacing: 2) {
            Text(value).font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(tint == .secondary ? .primary : tint)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Logic

    private func tick() {
        guard playing, points.count > 1 else { return }
        index += rate * 0.1
        if index >= Double(points.count - 1) {
            index = Double(points.count - 1)
            playing = false
        }
    }

    private func recenter() {
        guard let c = current else { return }
        cameraPosition = .camera(MapCamera(centerCoordinate: c.coordinate, distance: 2200, heading: 0, pitch: 0))
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
