import SwiftUI
import SwiftData
import MapKit

/// Full-screen picker for grading a past trip against a saved schedule. Replaces the old cramped
/// menu: each schedule is shown as a rich card (route, scheduled departure/arrival, predicted
/// travel, repeat, category, payer) so the user can tell them apart at a glance. Applying a schedule
/// only sets the trip's scheduled departure/arrival (and adopts the title/category) — it deliberately
/// never changes `paidBy`, the app's core "who pays for gas" data.
struct ApplyScheduleSheet: View {
    @Bindable var trip: DriveTrip
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \ScheduledDrive.createdAt, order: .reverse) private var schedules: [ScheduledDrive]
    @Query(sort: \SavedPlace.sortOrder) private var savedPlaces: [SavedPlace]
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]

    @State private var showManual = false

    private var isGraded: Bool { trip.scheduledArrival != nil || trip.scheduledDeparture != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if isGraded { currentGradingCard }

                    if schedules.isEmpty {
                        ContentUnavailableView("No saved schedules", systemImage: "calendar.badge.plus",
                            description: Text("Create a scheduled drive first, then apply it here to grade this trip on-time or delayed."))
                            .padding(.top, 24)
                    } else {
                        HStack {
                            Text("SAVED SCHEDULES").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ForEach(schedules) { s in scheduleCard(s) }
                    }

                    manualRow
                    if isGraded { removeButton }
                }
                .padding()
            }
            .background(.black)
            .navigationTitle("Apply a Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showManual) { EditTripScheduleView(trip: trip) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Grade this trip")
                .font(.title3.weight(.bold))
            Text("Pick the schedule this drive was meant to follow. Its departure and arrival times become this trip's targets, so it's scored on-time or delayed. Who pays for gas is left unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    /// Shows what the trip is currently graded against (if anything).
    private var currentGradingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Currently graded").font(.subheadline.weight(.semibold))
                if let arr = trip.scheduledArrival {
                    Text("Target arrival \(arr.formatted(.dateTime.hour().minute()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let delay = trip.delaySeconds {
                StatusChip(status: .forTrip(delaySeconds: delay))
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 14))
    }

    private func scheduleCard(_ s: ScheduledDrive) -> some View {
        Button { apply(s) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: s.category.icon).font(.subheadline).foregroundStyle(.blue)
                    Text(s.title).font(.headline).lineLimit(1)
                    Spacer()
                    PayerChip(PayerGroup.resolve(key: s.paidByRaw, in: payerGroups))
                }

                // Route: start → (stops) → destination
                HStack(spacing: 6) {
                    Image(systemName: "airplane.departure").font(.caption2).foregroundStyle(.green)
                    Text(name(s.startCoordinate, s.startAddress)).font(.caption).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    if !s.stops.isEmpty {
                        Text("\(s.stops.count) stop\(s.stops.count == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.orange)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Image(systemName: "airplane.arrival").font(.caption2).foregroundStyle(.red)
                    Text(name(s.endCoordinate, s.endAddress)).font(.caption).lineLimit(1)
                }

                HStack(spacing: 14) {
                    metric("DEPART", s.departure.formatted(.dateTime.hour().minute()), "airplane.departure")
                    metric("ARRIVE", s.scheduledArrival.formatted(.dateTime.hour().minute()), "airplane.arrival")
                    metric("TRAVEL", travelString(s.estimatedTravelTime), "clock.arrow.circlepath")
                }

                HStack(spacing: 8) {
                    tag(s.repeatRule.shortLabel, "repeat")
                    tag(s.category.label, s.category.icon)
                    Spacer()
                    Text("Apply").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.blue.gradient, in: .capsule)
                }
            }
            .padding()
            .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func metric(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value).font(.subheadline.weight(.semibold)).fontDesign(.rounded)
        }
    }

    private func tag(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.15), in: .capsule)
    }

    private var manualRow: some View {
        Button { showManual = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(.blue).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set times manually").font(.subheadline.weight(.semibold))
                    Text("Enter a custom departure & arrival to grade against").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.systemGray6), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            trip.scheduledArrival = nil
            trip.scheduledDeparture = nil
            try? context.save()
            Haptics.tap()
        } label: {
            Label("Remove schedule grading", systemImage: "xmark.circle")
                .font(.subheadline.weight(.medium)).foregroundStyle(.red)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color(.systemGray6), in: .capsule)
        }
    }

    private func name(_ coord: CLLocationCoordinate2D, _ fallback: String) -> String {
        PlaceNamer.name(for: coord, fallback: fallback, in: savedPlaces)
    }

    private func travelString(_ seconds: Int) -> String {
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }

    /// Apply a schedule's time-of-day targets to this trip (on the trip's own date), rolling arrival
    /// past midnight when it lands before departure. Adopts the title & category, but NEVER paidBy —
    /// grading a trip's timing must not silently change who pays for its gas.
    private func apply(_ s: ScheduledDrive) {
        Haptics.success()
        let cal = Calendar.current
        let d = cal.dateComponents([.hour, .minute], from: s.departure)
        let a = cal.dateComponents([.hour, .minute], from: s.scheduledArrival)
        let departure = cal.date(bySettingHour: d.hour ?? 0, minute: d.minute ?? 0, second: 0, of: trip.date)
        var arrival = cal.date(bySettingHour: a.hour ?? 0, minute: a.minute ?? 0, second: 0, of: trip.date)
        // Overnight schedule: arrival time-of-day precedes departure → it's the next day.
        if let dep = departure, let arr = arrival, arr < dep {
            arrival = cal.date(byAdding: .day, value: 1, to: arr)
        }
        trip.scheduledDeparture = departure
        trip.scheduledArrival = arrival
        trip.name = s.title
        trip.category = s.category
        // Intentionally NOT touching trip.paidBy — see doc comment.
        try? context.save()
        dismiss()
    }
}
