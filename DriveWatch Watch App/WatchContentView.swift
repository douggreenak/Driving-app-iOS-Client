import SwiftUI

/// The watch is a live-driving companion: while a drive is being recorded it shows that drive front
/// and center (speed, distance, time, ETA/delay, leg progress) with wrist controls; when idle it
/// shows the upcoming scheduled drives so one can be started from the wrist.
struct WatchContentView: View {
    @Environment(WatchConnectivityManager.self) private var link

    var body: some View {
        if let live = link.live {
            LiveDriveView(live: live, link: link)
        } else {
            UpNextView(link: link)
        }
    }
}

// MARK: - Live drive (the focus)

private struct LiveDriveView: View {
    let live: WatchSyncPayload.Live
    let link: WatchConnectivityManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 9) {
                    // Big current speed — the hero readout.
                    VStack(spacing: 0) {
                        Text("\(Int(live.currentSpeed.rounded()))")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .minimumScaleFactor(0.6).lineLimit(1)
                        Text("mph").font(.caption2).foregroundStyle(.secondary)
                    }

                    HStack {
                        readout(String(format: "%.1f", live.milesTraveled), "mi", .blue)
                        Divider().frame(height: 30)
                        readout(elapsed, "elapsed", .orange)
                    }

                    if live.eta != nil || live.legText != nil {
                        etaCard
                    }

                    if live.isPaused {
                        Text("Stopped — ready for the next leg").font(.caption2).foregroundStyle(.secondary)
                    }

                    controls.padding(.top, 2)
                }
                .padding(.horizontal, 4).padding(.vertical, 6)
            }
            .navigationTitle(live.tripName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func readout(_ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(tint)
                .monospacedDigit()
            Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var etaCard: some View {
        VStack(spacing: 6) {
            if let eta = live.eta {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ETA").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(eta, format: .dateTime.hour().minute()).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    if let text = delayText {
                        Text(text).font(.caption2.weight(.bold)).foregroundStyle(delayColor)
                    }
                }
            }
            if let progress = live.progress {
                ProgressView(value: progress).tint(delayColor)
            }
            if let legText = live.legText {
                HStack { Text(legText).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1); Spacer() }
            }
        }
        .padding(8)
        .background(.gray.opacity(0.16), in: .rect(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 5) {
            if live.isPaused {
                bigButton("Start Next Leg", "location.fill", .blue) { link.startNextLeg() }
                smallEnd
            } else if live.canAdvanceLeg {
                bigButton("Arrived — Next Stop", "checkmark.circle.fill", .green) { link.arriveAtStop() }
                smallEnd
            } else {
                bigButton("End Drive", "stop.fill", .red) { link.endDrive() }
            }
        }
    }

    private var smallEnd: some View {
        Button { link.endDrive() } label: {
            Text("End drive").font(.caption.weight(.semibold)).foregroundStyle(.red)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func bigButton(_ title: String, _ icon: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(tint.gradient, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var elapsed: String {
        let s = live.elapsedSeconds, h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private var delayColor: Color {
        guard let d = live.delaySeconds else { return .green }
        return d > 90 ? .orange : (d < -90 ? .blue : .green)
    }
    private var delayText: String? {
        guard let d = live.delaySeconds else { return nil }
        let m = max(1, abs(d) / 60)
        if d > 90 { return "\(m)m late" }
        if d < -90 { return "\(m)m early" }
        return "On time"
    }
}

// MARK: - Up Next (idle)

private struct UpNextView: View {
    let link: WatchConnectivityManager
    @State private var startedID: String?

    private var drives: [WatchSyncPayload.Drive] { link.payload?.drives ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                if drives.isEmpty {
                    ContentUnavailableView("No Drives", systemImage: "calendar",
                                           description: Text("Scheduled drives from your iPhone show up here."))
                        .padding(.top, 20)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(drives.enumerated()), id: \.element.id) { i, drive in
                            driveCard(drive, hero: i == 0)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .navigationTitle("Up Next")
        }
    }

    private func driveCard(_ drive: WatchSyncPayload.Drive, hero: Bool) -> some View {
        let started = startedID == drive.id
        return Button {
            startedID = drive.id
            link.startDrive(id: drive.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(drive.title).font(hero ? .headline : .subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: drive.payerIconName)
                        .font(.caption2).foregroundStyle(WatchPayerColor.color(for: drive.payerColorName))
                }
                HStack(spacing: 4) {
                    Image(systemName: "mappin").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(drive.endName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Image(systemName: started ? "checkmark.circle.fill" : "play.circle.fill")
                        .foregroundStyle(started ? .green : .blue)
                    Text(started ? "Starting on phone…" : relative(drive.departure))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(started ? .green : (isOverdue(drive.departure) ? .orange : .primary))
                    Spacer()
                }
                .font(.headline)
            }
            .padding(hero ? 12 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hero ? AnyShapeStyle(.blue.opacity(0.22)) : AnyShapeStyle(.gray.opacity(0.18)),
                        in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func isOverdue(_ date: Date) -> Bool { date.timeIntervalSinceNow < -60 }

    private func relative(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        let mins = abs(secs) / 60, h = mins / 60, m = mins % 60
        let body = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return secs >= 0 ? "in \(body)" : "\(body) ago"
    }
}
