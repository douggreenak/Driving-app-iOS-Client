import SwiftUI
import SwiftData
import MapKit

/// Alaska-Airlines-style detail for an upcoming scheduled drive: a map of the optimal route up
/// top, a prominent status banner, a flight-status schedule card, details, and Start / Cancel.
struct ScheduledDriveDetailView: View {
    @Bindable var drive: ScheduledDrive
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var loadingRoute = true
    @State private var showStart = false

    private var departure: Date { drive.statusReferenceDeparture() }
    private var arrival: Date { drive.targetArrival() }
    private var status: TripStatus { .upcoming(delaySeconds: drive.arrivalDelaySeconds(), isCanceled: drive.isCanceled) }

    // Start dot = departure status, end dot = arrival status (green / yellow / red).
    private var startColor: Color { drive.isCanceled ? .red : (drive.departureIsLate() ? .yellow : .green) }
    private var endColor: Color { drive.isCanceled ? .red : (drive.arrivalIsLate() ? .yellow : .green) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                mapHeader
                VStack(spacing: 16) {
                    StatusBanner(status: status)
                    scheduleCard
                    detailsCard
                    actions
                }
                .padding()
            }
        }
        .background(.black)
        .navigationTitle(drive.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRoute() }
        .fullScreenCover(isPresented: $showStart) { LiveTrackingView(scheduled: drive) }
    }

    // MARK: - Map header (optimal route)

    private var mapHeader: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition) {
                if routeCoords.count >= 2 {
                    MapPolyline(coordinates: routeCoords)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                Annotation("Departure", coordinate: drive.startCoordinate) { pin(startColor) }
                Annotation("Arrival", coordinate: drive.endCoordinate) { pin(endColor) }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 280)

            if loadingRoute {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding optimal route…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(.bottom, 12)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                .frame(height: 110).allowsHitTesting(false)

            HStack {
                endpoint(drive.startAddress, departure, startColor, .leading)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                endpoint(drive.endAddress, arrival, endColor, .trailing)
            }
            .padding()
        }
    }

    private func pin(_ color: Color) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 16, height: 16)
            Circle().stroke(.white, lineWidth: 2).frame(width: 16, height: 16)
        }
    }

    private func endpoint(_ title: String, _ time: Date, _ tint: Color, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            Text(time, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    // MARK: - Schedule card

    private var scheduleCard: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Schedule", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(drive.repeatRule.label).font(.caption.weight(.medium)).foregroundStyle(.blue)
            }
            HStack(alignment: .top) {
                timeColumn("DEPARTS", departure, drive.startAddress, .leading)
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "car.fill").foregroundStyle(.blue)
                    Text(travelString(drive.estimatedTravelTime)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                timeColumn("ARRIVES", arrival, drive.endAddress, .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.blue).frame(width: geo.size.width, height: 4)
                    Circle().fill(startColor).frame(width: 10, height: 10)
                    Circle().fill(endColor).frame(width: 10, height: 10).offset(x: geo.size.width - 10)
                }
            }
            .frame(height: 12)
            HStack {
                Text(departure, format: .dateTime.weekday(.wide).month().day())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !drive.isCanceled {
                    Text(TripStatus.countdown(to: departure)).font(.caption.weight(.semibold)).foregroundStyle(status.color)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private func timeColumn(_ label: String, _ time: Date, _ sub: String, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 3) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(time, format: .dateTime.hour().minute())
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    // MARK: - Details

    private var detailsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "dollarsign.circle.fill").foregroundStyle(drive.paidBy.tint).frame(width: 24)
                Text("Paid by").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(PaidBy.allCases, id: \.self) { p in
                        Button { drive.paidBy = p; try? context.save() } label: { Label(p.label, systemImage: p.icon) }
                    }
                } label: {
                    PayerChip(payer: drive.paidBy, compact: true)
                }
            }
            .font(.subheadline).padding(.vertical, 12)
            Divider()
            detailRow("car.fill", "Vehicle", drive.vehicleName ?? "Not set")
            Divider()
            detailRow(drive.category.icon, "Category", drive.category.label)
            Divider()
            detailRow("clock.arrow.circlepath", "Predicted travel", travelString(drive.estimatedTravelTime))
            Divider()
            detailRow("repeat", "Repeats", drive.repeatRule.label)
            if let notes = drive.notes, !notes.isEmpty {
                Divider()
                detailRow("note.text", "Notes", notes)
            }
        }
        .padding(.horizontal)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private func detailRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 24)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                showStart = true
            } label: {
                Label("Start Drive", systemImage: "play.fill")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background((drive.isCanceled ? Color.gray : .green).gradient, in: .capsule)
            }
            .disabled(drive.isCanceled)

            HStack(spacing: 12) {
                Button {
                    drive.isCanceled.toggle()
                    try? context.save()
                } label: {
                    Label(drive.isCanceled ? "Restore" : "Cancel",
                          systemImage: drive.isCanceled ? "arrow.uturn.backward" : "xmark.octagon")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(drive.isCanceled ? .blue : .orange)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.systemGray6), in: .capsule)
                }
                Button(role: .destructive) {
                    context.delete(drive)
                    try? context.save()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.systemGray6), in: .capsule)
                }
            }
        }
    }

    // MARK: - Route fetch

    private func loadRoute() async {
        let routes = await RouteMatcher.candidateRoutes(from: drive.startCoordinate, to: drive.endCoordinate)
        if let best = routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) {
            routeCoords = best.polyline.coordinates()
            // Refresh the stored predicted travel time from the live optimal route.
            drive.estimatedTravelTime = Int(best.expectedTravelTime)
            try? context.save()
        }
        let coords = routeCoords.isEmpty ? [drive.startCoordinate, drive.endCoordinate] : routeCoords
        cameraPosition = .region(.enclosing(coords))
        loadingRoute = false
    }

    private func travelString(_ seconds: Int) -> String {
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }
}
