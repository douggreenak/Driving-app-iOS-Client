import SwiftUI
import SwiftData

/// "Edit this trip" — the obvious place to fix where a trip ended, what schedule it's graded against,
/// and to record a diversion after the fact (you changed course mid-drive but didn't say so then).
struct TripEditCard: View {
    @Bindable var trip: DriveTrip
    var onChangeSchedule: () -> Void
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @State private var showDestination = false
    @State private var showDiversion = false

    private var endName: String {
        PlaceNamer.name(for: trip.endCoordinate, fallback: trip.endAddress, in: savedPlaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Edit this trip", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            row("mappin.and.ellipse", .red, "Change destination", endName) { showDestination = true }
            Divider().padding(.leading, 40)
            row("calendar.badge.clock", .blue, "Change schedule",
                trip.scheduledArrival.map { "Arrive " + $0.formatted(date: .abbreviated, time: .shortened) }
                    ?? "Not scheduled — tap to grade this trip") { onChangeSchedule() }
            Divider().padding(.leading, 40)
            row("arrow.triangle.turn.up.right.diamond.fill", .orange,
                trip.divertedFromName == nil ? "Add a diversion" : "Edit diversion",
                trip.divertedFromName.map { "Originally headed to \($0)" } ?? "Mark that you changed course") {
                showDiversion = true
            }
            if trip.divertedFromName != nil {
                Button("Remove diversion", role: .destructive) {
                    trip.divertedFromName = nil
                    try? context.save()
                    Haptics.tap()
                }
                .font(.caption).padding(.top, 6).padding(.leading, 40)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
        .sheet(isPresented: $showDestination) {
            LocationSearchSheet(title: "Where did you end up?") { picked in
                trip.endAddress = picked.address
                trip.endLat = picked.coordinate.latitude
                trip.endLng = picked.coordinate.longitude
                try? context.save()
                Haptics.success()
                pushEndpoints()
            }
        }
        .sheet(isPresented: $showDiversion) {
            LocationSearchSheet(title: "Where were you originally headed?") { picked in
                trip.divertedFromName = picked.address.split(separator: ",").first.map(String.init) ?? picked.address
                try? context.save()
                Haptics.success()
            }
        }
    }

    private func row(_ icon: String, _ tint: Color, _ title: String, _ subtitle: String,
                     _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body).foregroundStyle(tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Mirror the corrected endpoint to the cloud copy (best-effort; the phone stays the source of truth).
    private func pushEndpoints() {
        guard let remoteID = trip.remoteID else { return }
        let snapshot = (trip.date, trip.distance, trip.duration, trip.startAddress, trip.endAddress,
                        trip.startLat, trip.startLng, trip.endLat, trip.endLng, Polyline.encode(trip.displayCoordinates))
        Task {
            try? await APIClient.patchTripTrim(
                id: remoteID, date: ISO8601DateFormatter().string(from: snapshot.0),
                distance: snapshot.1, duration: max(1, (snapshot.2 + 30) / 60),
                startAddress: snapshot.3, endAddress: snapshot.4,
                startLat: snapshot.5, startLng: snapshot.6, endLat: snapshot.7, endLng: snapshot.8,
                routeEncoded: snapshot.9)
        }
    }
}

/// A Flighty-style layover pill: "1h 12m connection at Home", between two trips that share a stop.
/// A quiet connection marker between two stops, in the manner of Flighty's layover line: hairlines
/// either side of small secondary-colored text ("1h 10m connection · Home"). No fill, no color —
/// it reads as a footnote between the two trips, not as a third card. Only a tight connection
/// (under 20 minutes) picks up a touch of amber.
struct ConnectionPill: View {
    let seconds: Int
    let placeName: String
    var compact = false

    private var tight: Bool { seconds < 20 * 60 }

    var body: some View {
        HStack(spacing: 8) {
            hairline
            HStack(spacing: 4) {
                Image(systemName: "clock").imageScale(.small)
                Text(label).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.caption2)
            .foregroundStyle(tight ? Color.orange.opacity(0.85) : Color.secondary)
            .layoutPriority(1)
            hairline
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 0 : 2)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        let t = Connection.label(seconds)
        if compact || placeName.isEmpty { return "\(t) connection" }
        return "\(t) connection · \(placeName)"
    }

    private var hairline: some View {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
            .frame(minWidth: 12, maxWidth: .infinity)
    }
}
