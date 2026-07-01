import SwiftUI

/// Two screens on the watch: the upcoming drives (tap to start one on the phone) and a compact
/// stats summary.
struct WatchContentView: View {
    @Environment(WatchConnectivityManager.self) private var link

    var body: some View {
        TabView {
            DrivesTab(link: link)
            StatsTab(stats: link.payload?.stats)
        }
        .tabViewStyle(.verticalPage)
    }
}

private struct DrivesTab: View {
    let link: WatchConnectivityManager
    @State private var startedID: String?

    var body: some View {
        NavigationStack {
            List {
                if let drives = link.payload?.drives, !drives.isEmpty {
                    ForEach(drives) { drive in
                        Button {
                            startedID = drive.id
                            link.startDrive(id: drive.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(drive.title).font(.headline).lineLimit(1)
                                    if drive.paidByParents {
                                        Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.green)
                                    }
                                }
                                Text(drive.endName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                HStack(spacing: 4) {
                                    Image(systemName: startedID == drive.id ? "checkmark.circle.fill" : "play.circle.fill")
                                        .foregroundStyle(startedID == drive.id ? .green : .blue)
                                    Text(startedID == drive.id ? "Starting on phone…" : relative(drive.departure))
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No Drives", systemImage: "calendar",
                                           description: Text("Scheduled drives from your iPhone show up here."))
                }
            }
            .navigationTitle("Drives")
        }
    }

    private func relative(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        let mins = abs(secs) / 60, h = mins / 60, m = mins % 60
        let body = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return secs >= 0 ? "in \(body)" : "\(body) ago"
    }
}

private struct StatsTab: View {
    let stats: WatchSyncPayload.Stats?

    var body: some View {
        NavigationStack {
            List {
                if let stats {
                    row("Miles driven", String(format: "%.0f", stats.totalMiles), "road.lanes", .blue)
                    row("Drives", "\(stats.totalDrives)", "flag.checkered", .purple)
                    row("Gallons", String(format: "%.1f", stats.totalGallons), "fuelpump.fill", .green)
                } else {
                    ContentUnavailableView("No Stats Yet", systemImage: "chart.bar",
                                           description: Text("Open the app on your iPhone to sync."))
                }
            }
            .navigationTitle("Stats")
        }
    }

    private func row(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack {
            Label(title, systemImage: icon).foregroundStyle(tint)
            Spacer()
            Text(value).font(.headline).monospacedDigit()
        }
    }
}
