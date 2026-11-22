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

    @State private var confirmingEnd = false

    var body: some View {
        // Three vertical pages (Digital Crown / swipe): navigate, trip stats, controls.
        TabView {
            navigatePage
            statsPage
            controlsPage
        }
        .tabViewStyle(.verticalPage)
        .confirmationDialog("End this drive?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End Drive", role: .destructive) { link.endDrive() }
            Button("Keep Driving", role: .cancel) {}
        }
    }

    // MARK: Page 1 — navigate

    private var navigatePage: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let turn = live.nextTurn, !live.isPaused { turnCard(turn) }
                VStack(spacing: 0) {
                    Text("\(Int(live.currentSpeed.rounded()))")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("mph").font(.caption2).foregroundStyle(.secondary)
                }
                if live.eta != nil || live.legText != nil { etaCard }
                if live.isPaused {
                    Text("Stopped — ready for the next leg").font(.caption2).foregroundStyle(.secondary)
                }
                statusLine
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .navigationTitle(live.tripName)
    }

    // MARK: Page 2 — trip stats

    private var statsPage: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    readout(String(format: "%.1f", live.milesTraveled), "driven mi", .blue)
                    readout(live.remainingMiles.map { String(format: "%.1f", $0) } ?? "—", "left mi", .teal)
                }
                HStack(spacing: 4) {
                    readout(elapsedView, "elapsed", .orange)
                    readout(live.eta.map { $0.formatted(.dateTime.hour().minute()) } ?? "—", "arrival", .green)
                }
                HStack(spacing: 4) {
                    readout(live.maxSpeed.map { String(format: "%.0f", $0) } ?? "—", "max mph", .red)
                    readout(live.avgSpeed.map { String(format: "%.0f", $0) } ?? "—", "avg mph", .purple)
                }
                if let g = live.gallonsUsed {
                    readout(String(format: "%.2f", g), "gal used", .mint)
                }
                if let p = live.progress { ProgressView(value: p).tint(delayColor).padding(.top, 2) }
                statusLine
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .navigationTitle("Trip")
    }

    // MARK: Page 3 — controls

    private var controlsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                controls
                statusLine
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .navigationTitle("Controls")
    }

    /// Re-evaluated every few seconds so a frozen feed is called out instead of the last numbers
    /// sitting there looking live.
    private var statusLine: some View {
        VStack(spacing: 2) {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                if link.liveIsStale {
                    Label("Reconnecting to iPhone…", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if let err = link.lastSendError {
                Text(err).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
    }

    /// Ticks locally from the drive's start date between phone frames.
    @ViewBuilder private var elapsedView: some View {
        if let start = live.startDate, !live.isPaused {
            Text(start, style: .timer)
        } else {
            Text(elapsed)
        }
    }

    private func turnCard(_ turn: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: turnSymbol(turn)).font(.title3.weight(.bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Color.blue.gradient, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 0) {
                if let m = live.nextTurnMeters {
                    Text(turnDistance(m)).font(.system(.headline, design: .rounded)).monospacedDigit()
                }
                Text(turn).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.blue.opacity(0.16), in: .rect(cornerRadius: 12))
    }

    private func turnDistance(_ meters: Double) -> String {
        let miles = meters / 1609.34
        if miles >= 0.2 { return String(format: "%.1f mi", miles) }
        return "\(max(50, Int((meters * 3.28084 / 50).rounded() * 50))) ft"
    }

    private func turnSymbol(_ text: String) -> String {
        let t = text.lowercased()
        if t.contains("u-turn") { return "arrow.uturn.left" }
        if t.contains("left") { return t.contains("slight") || t.contains("bear") ? "arrow.up.left" : "arrow.turn.up.left" }
        if t.contains("right") { return t.contains("slight") || t.contains("bear") ? "arrow.up.right" : "arrow.turn.up.right" }
        if t.contains("arrive") || t.contains("destination") { return "mappin.circle.fill" }
        return "arrow.up"
    }

    private func readout(_ value: String, _ unit: String, _ tint: Color) -> some View {
        readout(Text(value), unit, tint)
    }

    private func readout<V: View>(_ value: V, _ unit: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            value.font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit()).foregroundStyle(tint)
            Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var etaCard: some View {
        VStack(spacing: 6) {
            if live.isPaused {
                HStack {
                    Text("Parked at stop").font(.caption.weight(.semibold))
                    Spacer()
                }
            } else if let eta = live.eta {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((live.legText == nil ? "ETA" : "Final ETA")
                             + (live.destinationName.map { " · \($0)" } ?? ""))
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        Text(eta, format: .dateTime.hour().minute()).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    if let text = delayText {
                        Text(text).font(.caption2.weight(.bold)).foregroundStyle(delayColor)
                    }
                }
            }
            if let eta = live.legEta {
                HStack(spacing: 3) {
                    Text("Next stop").foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(eta, format: .dateTime.hour().minute()).monospacedDigit().lineLimit(1)
                    if let miles = live.legRemainingMiles {
                        Text("· \(String(format: "%.1f mi", miles))").monospacedDigit().lineLimit(1)
                    }
                }
                .font(.caption2.weight(.medium)).minimumScaleFactor(0.7)
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
                bigButton("End Drive", "stop.fill", .red) { confirmingEnd = true }
            }
        }
    }

    private var smallEnd: some View {
        Button { confirmingEnd = true } label: {
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
        if d > 90 { return "\(m)m delayed" }
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
                if let err = link.lastSendError {
                    Text(err).font(.caption2).foregroundStyle(.orange).padding(.top, 6)
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
            // If the phone never takes over (unreachable, or the drive no longer exists there) the
            // card must not read "Starting on phone…" forever with no way to tap again.
            Task {
                try? await Task.sleep(for: .seconds(15))
                if startedID == drive.id, link.live == nil { startedID = nil }
            }
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
                    // `Text` below already carries its own explicit `.font`, so the stray
                    // `.font(.headline)` that used to sit on this whole HStack couldn't touch it —
                    // it only ever reached this `Image` (the one element here with no font of its
                    // own), rendering the status icon at headline size (~17pt) next to caption2
                    // text, visibly oversized compared to every sibling row's icon (e.g. the
                    // `mappin` row right above, sized to match its text at 9pt).
                    Image(systemName: started ? "checkmark.circle.fill" : "play.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(started ? .green : .blue)
                    Text(started ? "Starting on phone…" : relative(drive.departure))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(started ? .green : (isOverdue(drive.departure) ? .orange : .primary))
                    Spacer()
                }
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
