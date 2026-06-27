import SwiftUI
import MapKit

struct TripSummaryView: View {
    let tracker: LocationTracker
    let vehicle: Vehicle?
    var initialPaidBy: PaidBy = .myself
    let onSave: (TripCategory, PaidBy, String?) -> Void
    let onDiscard: () -> Void

    @State private var category: TripCategory = .other
    @State private var paidBy: PaidBy = .myself
    @State private var notes = ""
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var roadNames: [String] = []
    @State private var startAddress = ""
    @State private var endAddress = ""

    private var mpg: Double { vehicle?.avgMpg ?? 25 }
    private var gallonsUsed: Double { tracker.estimatedGallons(mpg: mpg) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    routeMap
                    statsGrid
                    gasEstimate
                    if !roadNames.isEmpty {
                        roadsList
                    }
                    addressSection
                    paidByPicker
                    categoryPicker
                    notesField
                }
                .padding()
            }
            .navigationTitle("Trip Complete")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { onDiscard() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Trip") { onSave(category, paidBy, notes.isEmpty ? nil : notes) }
                }
            }
            .onAppear { paidBy = initialPaidBy }
            .task { await resolveDetails() }
        }
    }

    // MARK: - Route Map

    private var routeMap: some View {
        Map(position: $cameraPosition) {
            if tracker.points.map(\.coordinate).count >= 2 {
                MapPolyline(coordinates: tracker.points.map(\.coordinate))
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = tracker.startCoordinate {
                Annotation("Start", coordinate: start) {
                    ZStack {
                        Circle().fill(.green).frame(width: 16, height: 16)
                        Circle().stroke(.white, lineWidth: 2).frame(width: 16, height: 16)
                    }
                }
            }
            if let end = tracker.endCoordinate {
                Annotation("End", coordinate: end) {
                    ZStack {
                        Circle().fill(.red).frame(width: 16, height: 16)
                        Circle().stroke(.white, lineWidth: 2).frame(width: 16, height: 16)
                    }
                }
            }
        }
        .frame(height: 250)
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Stats

    private var statsGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 12) {
            summaryStatBox(
                value: String(format: "%.1f", tracker.distanceMiles),
                unit: "miles",
                icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
                color: .blue
            )
            summaryStatBox(
                value: tracker.formattedElapsed(),
                unit: "duration",
                icon: "clock.fill",
                color: .orange
            )
            summaryStatBox(
                value: String(format: "%.0f", tracker.avgSpeedMph),
                unit: "avg mph",
                icon: "speedometer",
                color: .green
            )
        }
    }

    private func summaryStatBox(value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .fontDesign(.rounded)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Gas Estimate

    private var gasEstimate: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "fuelpump.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated Gas Used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f gallons", gallonsUsed))
                        .font(.title2)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                }
                Spacer()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vehicle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(vehicle?.name ?? "Default (25 MPG)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Fuel Economy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f MPG", mpg))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Roads

    private var roadsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Roads Traveled", systemImage: "road.lanes")
                .font(.subheadline)
                .fontWeight(.medium)

            FlowLayout(spacing: 6) {
                ForEach(roadNames, id: \.self) { road in
                    Text(road)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1), in: .capsule)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Addresses

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !startAddress.isEmpty || !endAddress.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("From", systemImage: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(startAddress.isEmpty ? "Resolving..." : startAddress)
                            .font(.subheadline)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("To", systemImage: "mappin")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(endAddress.isEmpty ? "Resolving..." : endAddress)
                            .font(.subheadline)
                    }
                }
                .padding()
                .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
            }
        }
    }

    // MARK: - Category & Notes

    private var paidByPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Who's paying for gas?", systemImage: "dollarsign.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(paidBy == .parents ? .green : .blue)
            Picker("Paid by", selection: $paidBy) {
                ForEach(PaidBy.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Category")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TripCategory.allCases, id: \.self) { cat in
                        Button {
                            withAnimation(.spring(duration: 0.25)) { category = cat }
                        } label: {
                            Label(cat.label, systemImage: cat.icon)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    category == cat
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.secondary.opacity(0.1),
                                    in: .capsule
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var notesField: some View {
        TextField("Notes (optional)", text: $notes, axis: .vertical)
            .lineLimit(3)
            .textFieldStyle(.roundedBorder)
            .padding()
            .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Resolve Addresses & Road Names

    private func resolveDetails() async {
        if let start = tracker.startCoordinate {
            startAddress = await reverseGeocode(start)
        }
        if let end = tracker.endCoordinate {
            endAddress = await reverseGeocode(end)
        }
        await resolveRoadNames()
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
        }
        do {
            let items = try await request.mapItems
            if let item = items.first {
                return item.name ?? item.placemark.title ?? String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
            }
        } catch {}
        return String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
    }

    private func resolveRoadNames() async {
        let coords = tracker.points.map(\.coordinate)
        guard coords.count >= 2 else { return }

        let sampleCount = min(coords.count, 12)
        let stride = max(coords.count / sampleCount, 1)
        var names = Set<String>()

        for i in Swift.stride(from: 0, to: coords.count, by: stride) {
            let coord = coords[i]
            let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            guard let request = MKReverseGeocodingRequest(location: location) else { continue }
            do {
                let items = try await request.mapItems
                if let item = items.first, let thoroughfare = item.placemark.thoroughfare {
                    names.insert(thoroughfare)
                }
            } catch {}
            try? await Task.sleep(for: .milliseconds(200))
        }

        await MainActor.run {
            roadNames = names.sorted()
        }
    }
}

// MARK: - Flow Layout for road name chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            if index < result.positions.count {
                let pos = result.positions[index]
                subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
            }
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
