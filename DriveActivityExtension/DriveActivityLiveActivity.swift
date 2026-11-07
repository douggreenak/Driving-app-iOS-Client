import ActivityKit
import WidgetKit
import SwiftUI

/// The trip Live Activity: a progress bar of how the drive is going, plus the scheduled arrival vs.
/// the live estimate (with on-time / delayed coloring), shown on the Lock Screen and in the
/// Dynamic Island.
///
/// Uses `DriveActivityAttributes` — add that file (from the app's `Models/` folder) to THIS
/// extension target's membership so both sides share the type.
struct DriveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            LockScreenView(context: context)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(speed(context), systemImage: "speedometer")
                            .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                        elapsedText(context).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(arrival(context), systemImage: "airplane.arrival")
                            .font(.caption.weight(.semibold)).foregroundStyle(delayColor(context))
                        Text(delayStatus(context)).font(.caption2).foregroundStyle(delayColor(context))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if let turn = context.state.nextTurn, !context.state.isPaused {
                        HStack(spacing: 6) {
                            Image(systemName: turnSymbol(turn)).foregroundStyle(.blue)
                            if let m = context.state.nextTurnMeters {
                                Text(turnDistance(m)).font(.caption.weight(.bold)).monospacedDigit()
                            }
                            Text(turn).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        if let progress = context.state.progress {
                            ProgressView(value: progress).tint(delayColor(context))
                        }
                        HStack(spacing: 4) {
                            Text(context.state.destinationName ?? title(context))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(distanceSummary(context)).monospacedDigit().lineLimit(1)
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // The next maneuver's arrow when there is one — the one thing worth a glance.
                if let turn = context.state.nextTurn, !context.state.isPaused {
                    Image(systemName: turnSymbol(turn)).foregroundStyle(.blue)
                } else {
                    Image(systemName: "airplane.departure").foregroundStyle(.blue)
                }
            } compactTrailing: {
                Text(shortProgress(context)).font(.caption2).monospacedDigit()
            } minimal: {
                if let turn = context.state.nextTurn, !context.state.isPaused {
                    Image(systemName: turnSymbol(turn)).foregroundStyle(.blue)
                } else if let p = context.state.progress {
                    ProgressView(value: p).progressViewStyle(.circular).tint(delayColor(context))
                } else {
                    Image(systemName: "airplane.departure").foregroundStyle(.blue)
                }
            }
            // Tapping the Dynamic Island (expanded or compact) or the Lock Screen banner (see
            // `LockScreenView` below) opens the app straight at the live tracking screen — see
            // `ContentView.onOpenURL`. Without this the tap just opened the app on whatever tab was
            // last selected, leaving the currently-tracking drive minimized with no obvious way back.
            .widgetURL(URL(string: "drivetracker://active-drive"))
        }
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

    /// See `LockScreenView.title` — the live title lives in `state`, with the fixed attribute as a
    /// defensive fallback.
    private func title(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        c.state.tripTitle ?? c.attributes.tripTitle
    }
    private func miles(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        String(format: "%.1f mi", c.state.milesTraveled)
    }
    private func speed(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        String(format: "%.0f mph", c.state.currentSpeed)
    }
    /// Elapsed time, ticking in the widget itself when the push carried a start date (no update per
    /// second needed); the pushed `elapsedSeconds` is the fallback for an older snapshot.
    private func elapsedText(_ c: ActivityViewContext<DriveActivityAttributes>) -> Text {
        // `.relative` ("23 min", "1 hr, 4 min") updates by the minute with no seconds — a seconds
        // timer renders as "24:––" whenever the Lock Screen is dimmed, which reads as broken.
        if let start = c.state.startDate { return Text(start, style: .relative) }
        let seconds = c.state.elapsedSeconds
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return Text(hours > 0 ? String(format: "%d:%02d", hours, minutes) : String(format: "%d min", minutes))
    }
    private func distanceSummary(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        guard let remaining = c.state.remainingMiles else { return miles(c) }
        return "\(miles(c)) · \(String(format: "%.1f mi left", remaining))"
    }
    private func arrival(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        if c.state.isPaused { return "Parked" }
        guard let eta = c.state.eta else { return "—" }
        return eta.formatted(date: .omitted, time: .shortened)
    }
    private func delayStatus(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        if c.state.isPaused { return "At stop" }
        guard let delay = c.state.delaySeconds else { return "Estimated arrival" }
        if delay > 90 { return "\(max(1, delay / 60))m late" }
        if delay < -90 { return "\(max(1, abs(delay) / 60))m early" }
        return "On time"
    }
    /// `progress` is nil for a destination-less ad-hoc drive (no remaining-distance to measure
    /// against) — showing "0%" for the whole compact-trailing slot then reads as a frozen/broken
    /// activity for the entire drive. Fall back to the one number that IS live for that case.
    private func shortProgress(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        guard let p = c.state.progress else { return String(format: "%.1f mi", c.state.milesTraveled) }
        return "\(Int(p * 100))%"
    }
    private func delayColor(_ c: ActivityViewContext<DriveActivityAttributes>) -> Color {
        if c.state.isPaused { return .blue }
        guard let d = c.state.delaySeconds else { return .green }
        if d > 90 { return Color(red: 1.0, green: 0.62, blue: 0.04) }
        return d < -90 ? .blue : .green
    }
}

/// The full Lock Screen layout: title, progress bar, and scheduled-vs-estimated arrival.
private struct LockScreenView: View {
    let context: ActivityViewContext<DriveActivityAttributes>

    private var delayColor: Color {
        if context.state.isPaused { return .blue }
        guard let d = context.state.delaySeconds else { return .green }
        if d > 90 { return Color(red: 1.0, green: 0.62, blue: 0.04) }
        return d < -90 ? .blue : .green
    }

    /// `ContentState.tripTitle`/`scheduledArrival` are the live values — a drive's title and
    /// schedule can both change after the activity starts (see `ContentState`'s doc comment) — with
    /// the fixed `ActivityAttributes` fields as a fallback for the (practically impossible) case a
    /// push landed without them.
    private var title: String { context.state.tripTitle ?? context.attributes.tripTitle }
    private var scheduledArrival: Date? { context.state.scheduledArrival ?? context.attributes.scheduledArrival }

    private var statusText: String {
        if context.state.isPaused { return "Parked at a stop" }
        guard let d = context.state.delaySeconds else { return "On the way" }
        let mins = max(1, abs(d) / 60)
        if d > 90 { return "\(mins) min delayed" }
        if d < -90 { return "\(mins) min early" }
        return "On time"
    }

    private var hasTurn: Bool { context.state.nextTurn != nil && !context.state.isPaused }

    /// Lock Screen Live Activities get ~160 pt of height; the old layout stacked seven rows and spilled
    /// past both edges. This keeps four quiet rows: who/where + status, the next turn (only when there
    /// is one), the arrival time, and a single line of small stats.
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 1. Title + one status word.
            HStack(spacing: 8) {
                Image(systemName: "airplane.departure").font(.footnote).foregroundStyle(.blue)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 6)
                Text(statusText).font(.caption.weight(.semibold)).foregroundStyle(delayColor).lineLimit(1)
            }

            // 2. Next maneuver from the phone's guide route.
            if hasTurn, let turn = context.state.nextTurn {
                HStack(spacing: 10) {
                    Image(systemName: turnSymbol(turn)).font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Color.blue.gradient, in: .rect(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 0) {
                        if let m = context.state.nextTurnMeters {
                            Text(turnDistance(m)).font(.subheadline.weight(.bold)).foregroundStyle(.white).monospacedDigit()
                        }
                        Text(turn).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }

            // Nil (not a permanent 0%) for a destination-less drive: an empty bar all trip reads as broken.
            if let progress = context.state.progress {
                ProgressView(value: progress).tint(delayColor).scaleEffect(y: 0.8)
            }

            // 3. Arrival, big; scheduled time small beside it. A destination-less drive has no ETA —
            //    the elapsed timer is the hero then, rather than a dash for the whole trip.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                heroText
                    .font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(delayColor)
                if !context.state.isPaused {
                    Text(context.state.eta == nil ? "elapsed" : (context.state.isMultiLeg == true ? "final ETA" : "arrival"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let sched = scheduledArrival {
                    Text("Scheduled \(sched.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            // 4. One line of small stats — or, parked between stops, where you're headed next.
            Group {
                if let eta = context.state.legEta {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(.blue)
                        Text("Next: \(context.state.legDestinationName ?? "Stop")").lineLimit(1)
                        Spacer(minLength: 2)
                        Text(eta.formatted(date: .omitted, time: .shortened))
                    }
                } else {
                    statsLine.lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        // Tapping the Lock Screen banner opens the app straight at the live tracking screen — see
        // the Dynamic Island's matching `.widgetURL` above and `ContentView.onOpenURL`.
        .widgetURL(URL(string: "drivetracker://active-drive"))
    }

    private var heroText: Text {
        if context.state.isPaused { return Text("Parked") }
        if let eta = context.state.eta { return Text(eta.formatted(date: .omitted, time: .shortened)) }
        return elapsedText
    }

    private var statsLine: Text {
        var parts: [String] = []
        if let r = context.state.remainingMiles { parts.append(String(format: "%.1f mi left", r)) }
        parts.append(String(format: "%.1f mi driven", context.state.milesTraveled))
        parts.append(String(format: "%.0f mph", context.state.currentSpeed))
        let base = Text(parts.joined(separator: " · "))
        // The elapsed timer already is the hero line when there's no ETA; don't repeat it.
        if context.state.eta == nil, !context.state.isPaused { return base }
        return base + Text(" · ") + elapsedText
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

    /// Ticks on its own from the pushed start date (see `ContentState.startDate`).
    private var elapsedText: Text {
        if let start = context.state.startDate { return Text(start, style: .relative) }
        let seconds = context.state.elapsedSeconds
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return Text(hours > 0 ? String(format: "%d:%02d", hours, minutes) : String(format: "%d min", minutes))
    }
}
