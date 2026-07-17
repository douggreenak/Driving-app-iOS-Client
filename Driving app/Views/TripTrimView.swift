import SwiftUI
import SwiftData
import MapKit

/// Trim a recorded trip's start and/or end — for when you forget to stop tracking (a stationary
/// tail) or started it late. A map shows the full track with the kept portion highlighted and the
/// discarded head/tail dimmed; two sliders set the cut points and a live card previews the resulting
/// distance, duration, and times. Applying is destructive (with a confirmation).
struct TripTrimView: View {
    @Bindable var trip: DriveTrip
    var onTrimmed: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private let points: [TrackPoint]
    @State private var startIdx: Double = 0
    @State private var endIdx: Double = 0
    @State private var saving = false
    @State private var showConfirm = false

    init(trip: DriveTrip, onTrimmed: @escaping () -> Void = {}) {
        self.trip = trip
        self.onTrimmed = onTrimmed
        self.points = trip.orderedPoints
        _endIdx = State(initialValue: Double(max(points.count - 1, 0)))
    }

    private var loI: Int { min(max(0, Int(startIdx.rounded())), points.count - 1) }
    private var hiI: Int { min(max(loI + 1, Int(endIdx.rounded())), points.count - 1) }
    private var lastI: Int { points.count - 1 }
    private var trimmed: Bool { loI > 0 || hiI < lastI }

    var body: some View {
        NavigationStack {
            Group {
                if points.count < 2 {
                    ContentUnavailableView("Not enough track", systemImage: "scissors",
                        description: Text("This trip doesn't have enough recorded points to trim."))
                } else {
                    content
                }
            }
            .background(.black)
            .navigationTitle("Trim Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trim") { showConfirm = true }.disabled(!trimmed || saving)
                }
            }
            .confirmationDialog("Trim this trip?", isPresented: $showConfirm, titleVisibility: .visible) {
                Button("Trim Trip", role: .destructive) { apply() }
            } message: {
                Text("This permanently removes \(removedCount) recorded point\(removedCount == 1 ? "" : "s") from the drive. It can't be undone.")
            }
            .overlay {
                if saving {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.large).tint(.white)
                            Text("Trimming…").font(.subheadline).foregroundStyle(.white)
                        }
                    }
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                map.frame(height: 280).clipShape(.rect(cornerRadius: 16))
                previewCard
                quickActions
                sliders
            }
            .padding()
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(initialPosition: .region(.enclosing(points.map(\.coordinate)))) {
            // Dimmed discarded head + tail.
            if loI > 0 {
                MapPolyline(coordinates: Array(points[0...loI]).map(\.coordinate))
                    .stroke(.gray.opacity(0.4), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            if hiI < lastI {
                MapPolyline(coordinates: Array(points[hiI...lastI]).map(\.coordinate))
                    .stroke(.gray.opacity(0.4), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            // Kept portion.
            MapPolyline(coordinates: Array(points[loI...hiI]).map(\.coordinate))
                .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            Annotation("Start", coordinate: points[loI].coordinate) { endDot(.green) }
            Annotation("End", coordinate: points[hiI].coordinate) { endDot(.red) }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func endDot(_ color: Color) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 16, height: 16)
            Circle().stroke(.white, lineWidth: 2).frame(width: 16, height: 16)
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        VStack(spacing: 12) {
            HStack {
                previewStat(String(format: "%.1f mi", keptMiles), "distance", "point.topleft.down.to.point.bottomright.curvepath.fill", .blue)
                Divider().frame(height: 34)
                previewStat(durationString(keptSeconds), "duration", "clock.fill", .orange)
            }
            Divider()
            HStack {
                timeCol("NEW START", points[loI].t, .green)
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Spacer()
                timeCol("NEW END", points[hiI].t, .red)
            }
            if trimmed {
                HStack(spacing: 14) {
                    if loI > 0 {
                        Label("−\(durationString(Int(points[loI].t.timeIntervalSince(points[0].t)))) from start",
                              systemImage: "scissors").font(.caption2).foregroundStyle(.secondary)
                    }
                    if hiI < lastI {
                        Label("−\(durationString(Int(points[lastI].t.timeIntervalSince(points[hiI].t)))) from end",
                              systemImage: "scissors").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private func previewStat(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.headline).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(.title3, design: .rounded, weight: .bold))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func timeCol(_ label: String, _ time: Date, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(time, format: .dateTime.hour().minute())
                .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(tint)
        }
    }

    // MARK: - Quick actions

    @ViewBuilder
    private var quickActions: some View {
        let tail = idleTailIndex
        let head = idleHeadIndex
        if tail != nil || head != nil || trimmed {
            HStack(spacing: 8) {
                if let tail {
                    quickChip("Trim idle tail", "arrow.down.right.and.arrow.up.left") {
                        withAnimation { endIdx = Double(tail) }
                    }
                }
                if let head {
                    quickChip("Trim idle start", "arrow.up.left.and.arrow.down.right") {
                        withAnimation { startIdx = Double(head) }
                    }
                }
                if trimmed {
                    quickChip("Reset", "arrow.uturn.backward") {
                        withAnimation { startIdx = 0; endIdx = Double(lastI) }
                    }
                }
                Spacer()
            }
        }
    }

    private func quickChip(_ text: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.blue.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain).foregroundStyle(.blue)
    }

    // MARK: - Sliders

    private var sliders: some View {
        VStack(spacing: 18) {
            sliderRow(title: "Start", tint: .green, value: $startIdx,
                      range: 0...Double(max(hiI - 1, 0)), time: points[loI].t)
            sliderRow(title: "End", tint: .red, value: $endIdx,
                      range: Double(min(loI + 1, lastI))...Double(lastI), time: points[hiI].t)
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private func sliderRow(title: String, tint: Color, value: Binding<Double>, range: ClosedRange<Double>, time: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: "circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text(time, format: .dateTime.hour().minute().second())
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range.lowerBound <= range.upperBound ? range : 0...Double(lastI))
                .tint(tint)
        }
    }

    // MARK: - Idle detection

    /// Last index the car was actually moving (>3 mph). If it's before the end, the tail is a
    /// stationary "forgot to stop" segment worth trimming.
    private var idleTailIndex: Int? {
        guard let last = points.lastIndex(where: { $0.speed > 3 }), last < lastI - 1, last > loI else { return nil }
        return last
    }
    /// First index the car started moving, if there's a stationary lead-in.
    private var idleHeadIndex: Int? {
        guard let firstMove = points.firstIndex(where: { $0.speed > 3 }), firstMove > 1, firstMove < hiI else { return nil }
        return firstMove
    }

    // MARK: - Derived preview values

    private var keptMiles: Double {
        guard hiI > loI else { return 0 }
        var m = 0.0
        for i in (loI + 1)...hiI {
            let step = points[i - 1].coordinate.distanceMeters(to: points[i].coordinate)
            if step < 500 { m += step }
        }
        return m / 1609.34
    }
    private var keptSeconds: Int { Int(points[hiI].t.timeIntervalSince(points[loI].t)) }
    private var removedCount: Int { (loI) + (lastI - hiI) }

    private func durationString(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    // MARK: - Apply

    private func apply() {
        saving = true
        Haptics.warning()
        let keepStart = loI, keepEnd = hiI
        Task { @MainActor in
            await TripStore.applyTrim(trip: trip, keepStart: keepStart, keepEnd: keepEnd, context: context)
            saving = false
            onTrimmed()
            dismiss()
        }
    }
}
