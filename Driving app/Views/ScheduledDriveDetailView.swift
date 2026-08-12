import SwiftUI
import SwiftData
import MapKit

/// Alaska-Airlines-style detail for an upcoming scheduled drive: a map of the optimal route up
/// top, a prominent status banner, a flight-status schedule card, details, and Start / Cancel.
struct ScheduledDriveDetailView: View {
    @Bindable var drive: ScheduledDrive
    /// The specific occurrence this page was opened for (from the departures board). When nil (e.g.
    /// opened from the dashboard Up Next), fall back to the drive's next/overdue occurrence.
    var occurrence: Date? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]

    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var loadingRoute = true
    @State private var showStart = false
    @State private var showEdit = false
    @State private var showDeleteConfirm = false

    // Anchor the page on the tapped occurrence when we have one, else the drive's Up Next occurrence
    // — the next one still to make (or the current one if it's overdue and unstarted).
    // statusReferenceDeparture() alone could point back at a just-completed past occurrence, showing
    // a stale DEPARTED banner for a drive already finished.
    private var departure: Date { occurrence ?? drive.upNextDeparture() ?? drive.statusReferenceDeparture() }
    private var arrival: Date { departure.addingTimeInterval(drive.arrivalBudget) }

    // Show a bookmarked place's name ("Home") instead of the street address when one is nearby.
    private var startName: String {
        PlaceNamer.name(for: drive.startCoordinate, fallback: drive.startAddress, in: savedPlaces)
    }
    private var endName: String {
        PlaceNamer.name(for: drive.endCoordinate, fallback: drive.endAddress, in: savedPlaces)
    }
    // Canceling only cancels the occurrence this page is showing — the repeat keeps going.
    private var isCanceled: Bool { drive.isOccurrenceCanceled(departure) }
    private var status: TripStatus {
        .occurrence(departure: departure, scheduledArrival: arrival, travelSeconds: drive.estimatedTravelTime,
                    isCanceled: isCanceled, startedAt: drive.lastStartedAt)
    }

    // Start dot = departure status, end dot = arrival status (green / yellow / red). Overdue is
    // measured against the same anchored occurrence the banner uses, so the dots never disagree with
    // the status (e.g. a green ON TIME banner next to yellow "late" dots). A not-yet-started drive is
    // never pre-judged as delayed from its raw predicted travel time.
    private var isOverdueToDepart: Bool { Date().timeIntervalSince(departure) > 90 }
    private var startColor: Color { isCanceled ? .red : (isOverdueToDepart ? .yellow : .green) }
    private var endColor: Color { isCanceled ? .red : (isOverdueToDepart ? .yellow : .green) }

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEdit = true } label: { Image(systemName: "pencil") }
            }
        }
        .task { await loadRoute() }
        .fullScreenCover(isPresented: $showStart) { LiveTrackingView(scheduled: drive) }
        .sheet(isPresented: $showEdit) { NewScheduledDriveView(editing: drive, occurrenceDate: departure) }
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
                ForEach(Array(drive.stops.enumerated()), id: \.element.id) { i, stop in
                    Annotation(stop.dwellMinutes > 0 ? "Stop \(i + 1) · \(stop.dwellMinutes) min" : "Stop \(i + 1)",
                               coordinate: stop.coordinate) { stopPin(i + 1, dwell: stop.dwellMinutes) }
                }
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
                endpoint(startName, departure, startColor, .leading)
                Spacer(minLength: 8)
                VStack(spacing: 4) {
                    Image(systemName: "airplane.departure").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    Image(systemName: "airplane.arrival").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                endpoint(endName, arrival, endColor, .trailing)
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

    /// A numbered pin for an intermediate stop, optionally showing the dwell time.
    private func stopPin(_ number: Int, dwell: Int = 0) -> some View {
        VStack(spacing: 2) {
            Text("\(number)")
                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.orange, in: .circle)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            if dwell > 0 {
                Text("+\(dwell)m")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.orange.opacity(0.85), in: .capsule)
            }
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
                timeColumn("DEPARTS", departure, startName, .leading)
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "airplane.departure").foregroundStyle(.blue)
                    Text(travelString(drive.estimatedTravelTime)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                timeColumn("ARRIVES", arrival, endName, .trailing)
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
                if !isCanceled {
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
            // If any stop has dwell time, show a breakdown so the user can see drive vs. stop time.
            let totalDwell = drive.stops.reduce(0) { $0 + $1.dwellMinutes }
            if totalDwell > 0 {
                Divider()
                VStack(spacing: 0) {
                    ForEach(drive.stops.filter { $0.dwellMinutes > 0 }.indices, id: \.self) { i in
                        let stop = drive.stops.filter { $0.dwellMinutes > 0 }[i]
                        let idx = drive.stops.firstIndex(where: { $0.id == stop.id }).map { $0 + 1 } ?? (i + 1)
                        HStack(spacing: 12) {
                            Image(systemName: "clock.badge.fill").foregroundStyle(.orange).frame(width: 24)
                            Text("Stop \(idx) dwell").foregroundStyle(.secondary)
                            Spacer()
                            Text("+\(stop.dwellMinutes) min").fontWeight(.medium)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 10)
                        if i < drive.stops.filter({ $0.dwellMinutes > 0 }).count - 1 { Divider() }
                    }
                }
            }
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
                Haptics.tap()
                showStart = true
            } label: {
                Label("Start Drive", systemImage: "play.fill")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background((isCanceled ? Color.gray : .green).gradient, in: .capsule)
            }
            .disabled(isCanceled)

            HStack(spacing: 12) {
                Button {
                    Haptics.selection()
                    drive.setOccurrenceCanceled(departure, !isCanceled)
                    try? context.save()
                    Task { await ScheduledDriveStore.sync(context: context) }
                } label: {
                    Label(isCanceled ? "Restore" : "Cancel",
                          systemImage: isCanceled ? "arrow.uturn.backward" : "xmark.octagon")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isCanceled ? .blue : .orange)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.systemGray6), in: .capsule)
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.systemGray6), in: .capsule)
                }
            }
        }
        .confirmationDialog("Delete this scheduled drive?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Drive", role: .destructive) {
                Haptics.warning()
                let removedRemoteID = drive.remoteID
                let doomed = drive
                let ctx = context
                // Pop FIRST, then delete: `drive` is @Bindable and read all over this body, so
                // deleting it while the view is still on screen risks a re-render dereferencing an
                // invalidated SwiftData model. Deleting after the pop avoids that.
                dismiss()
                Task { @MainActor in
                    ctx.delete(doomed)
                    try? ctx.save()
                    if let id = removedRemoteID { try? await APIClient.deleteScheduledDrive(id: id) }
                    await ScheduledDriveStore.sync(context: ctx)
                }
            }
        } message: {
            Text(drive.repeatRule == .none
                 ? "This removes the scheduled drive."
                 : "This is a repeating drive — deleting it removes all of its occurrences.")
        }
    }

    // MARK: - Route fetch

    private func loadRoute() async {
        // Route through every waypoint (start → stops → destination), summing the legs.
        if let result = await RouteMatcher.multiLegRoute(through: drive.routeCoordinates) {
            routeCoords = result.coordinates
            // Refresh the stored predicted travel time from the live optimal multi-leg route.
            drive.estimatedTravelTime = result.seconds
            try? context.save()
        }
        let coords = routeCoords.isEmpty ? drive.routeCoordinates : routeCoords
        cameraPosition = .region(.enclosing(coords))
        loadingRoute = false
    }

    private func travelString(_ seconds: Int) -> String {
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }
}
