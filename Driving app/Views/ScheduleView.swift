import SwiftUI
import SwiftData

/// One unified schedule: a Flightradar24 / airport-style departures board where every occurrence
/// of every (repeating) drive is its own row — time, who's paying, destination, and a clear
/// status. Swipe to cancel or delete; tap for the full detail page.
struct ScheduleView: View {
    @Query private var drives: [ScheduledDrive]
    @State private var showingNew = false
    @State private var pendingDelete: ScheduledDrive?

    /// All today/upcoming occurrences across all drives, grouped by day.
    private var grouped: [(day: Date, items: [DriveOccurrence])] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 14, to: start) ?? start
        var all: [DriveOccurrence] = []
        for drive in drives {
            for dep in drive.occurrences(in: start...end) {
                let occ = DriveOccurrence(drive: drive, departure: dep,
                                          arrival: dep.addingTimeInterval(drive.arrivalBudget))
                // Once a trip has arrived (tracking stopped within this occurrence's window),
                // drop it from the board.
                if occ.isCompleted { continue }
                all.append(occ)
            }
        }
        let dict = Dictionary(grouping: all) { cal.startOfDay(for: $0.departure) }
        return dict.keys.sorted().map { day in
            (day, dict[day]!.sorted { $0.departure < $1.departure })
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if drives.isEmpty {
                    emptyState
                } else {
                    board
                }
            }
            .background(.black)
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingNew) { NewScheduledDriveView() }
            .confirmationDialog("Delete this scheduled drive?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Drive", role: .destructive) {
                    if let d = pendingDelete {
                        Haptics.warning()
                        let ctx = d.modelContext
                        ctx?.delete(d)
                        try? ctx?.save()
                    }
                    pendingDelete = nil
                }
            } message: {
                let repeats = (pendingDelete?.repeatRule ?? .none) != .none
                Text(repeats
                     ? "This is a repeating drive — deleting it removes all of its occurrences."
                     : "This removes the scheduled drive.")
            }
        }
    }

    private var board: some View {
        let groups = grouped
        return List {
            if groups.isEmpty {
                ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                    description: Text("No drives in the next two weeks."))
            }
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.items) { occ in
                        NavigationLink {
                            ScheduledDriveDetailView(drive: occ.drive)
                        } label: {
                            DepartureRow(occ: occ)
                        }
                        .swipeActions(edge: .leading) { cancelButton(occ.drive) }
                        .swipeActions(edge: .trailing) { deleteButton(occ.drive) }
                    }
                }
                header: { Text(dayLabel(group.day)) }
            }
        }
        .listStyle(.plain)
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }

    private func cancelButton(_ drive: ScheduledDrive) -> some View {
        Button {
            Haptics.selection()
            drive.isCanceled.toggle()
            try? drive.modelContext?.save()
        } label: {
            Label(drive.isCanceled ? "Restore" : "Cancel",
                  systemImage: drive.isCanceled ? "arrow.uturn.backward" : "xmark.octagon")
        }
        .tint(drive.isCanceled ? .blue : .orange)
    }

    private func deleteButton(_ drive: ScheduledDrive) -> some View {
        Button(role: .destructive) {
            pendingDelete = drive
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Scheduled Drives", systemImage: "calendar.badge.plus")
        } description: {
            Text("Schedule a drive and we'll predict the travel time and arrival.")
        } actions: {
            Button("Schedule a Drive") { showingNew = true }.buttonStyle(.borderedProminent)
        }
    }
}

/// One occurrence of a scheduled drive (a single departure on a specific date).
struct DriveOccurrence: Identifiable {
    let drive: ScheduledDrive
    let departure: Date
    let arrival: Date
    var id: String { "\(drive.id)-\(departure.timeIntervalSince1970)" }

    /// Was this occurrence actually driven (a recorded start in its window)?
    var isDeparted: Bool {
        guard let s = drive.lastStartedAt else { return false }
        return s >= departure.addingTimeInterval(-1800) && s <= arrival.addingTimeInterval(3 * 3600)
    }

    /// Has this occurrence arrived (tracking stopped within its window)? Completed occurrences
    /// drop off the board.
    var isCompleted: Bool {
        guard let c = drive.lastCompletedAt else { return false }
        return c >= departure.addingTimeInterval(-1800) && c <= arrival.addingTimeInterval(6 * 3600)
    }

    var status: TripStatus {
        .occurrence(departure: departure, scheduledArrival: arrival,
                    travelSeconds: drive.estimatedTravelTime, isCanceled: drive.isCanceled,
                    startedAt: drive.lastStartedAt)
    }

    /// Start dot = departure status: green on time, yellow if late to depart, red if canceled.
    var startColor: Color {
        if drive.isCanceled { return .red }
        if isDeparted { return .gray }
        return Date() > departure ? .yellow : .green
    }

    /// End dot = arrival status: green on schedule, yellow if projected late, red if canceled.
    var endColor: Color {
        if drive.isCanceled { return .red }
        if isDeparted { return .gray }
        let estimated = max(departure, Date()).addingTimeInterval(TimeInterval(drive.estimatedTravelTime))
        return estimated.timeIntervalSince(arrival) > 90 ? .yellow : .green
    }
}

/// Airport-departures-board row: status dots + times, who's paying, destination, and a status chip.
struct DepartureRow: View {
    let occ: DriveOccurrence

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(occ.startColor).frame(width: 7, height: 7)
                    Text(occ.departure, format: .dateTime.hour().minute())
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit().lineLimit(1).fixedSize()
                }
                HStack(spacing: 6) {
                    Circle().fill(occ.endColor).frame(width: 7, height: 7)
                    Text(occ.arrival, format: .dateTime.hour().minute())
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            .frame(width: 86, alignment: .leading)

            Rectangle().fill(.secondary.opacity(0.25)).frame(width: 1, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: occ.drive.category.icon)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(occ.drive.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    Image(systemName: occ.drive.paidBy.icon)
                        .font(.caption2).foregroundStyle(occ.drive.paidBy.tint)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(occ.drive.endAddress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            StatusChip(status: occ.status, compact: true)
        }
        .padding(.vertical, 4)
        .opacity(occ.drive.isCanceled ? 0.5 : 1)
    }
}
