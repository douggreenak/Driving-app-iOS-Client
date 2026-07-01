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
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(miles(context), systemImage: "road.lanes").font(.caption).foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(arrival(context), systemImage: "flag.checkered")
                        .font(.caption).foregroundStyle(delayColor(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(value: context.state.progress ?? 0)
                            .tint(delayColor(context))
                        Text(context.attributes.tripTitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "car.fill").foregroundStyle(.blue)
            } compactTrailing: {
                Text(shortProgress(context)).font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: "car.fill").foregroundStyle(.blue)
            }
        }
    }

    private func miles(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        String(format: "%.1f mi", c.state.milesTraveled)
    }
    private func arrival(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        guard let eta = c.state.eta else { return "—" }
        return eta.formatted(date: .omitted, time: .shortened)
    }
    private func shortProgress(_ c: ActivityViewContext<DriveActivityAttributes>) -> String {
        "\(Int((c.state.progress ?? 0) * 100))%"
    }
    private func delayColor(_ c: ActivityViewContext<DriveActivityAttributes>) -> Color {
        guard let d = c.state.delaySeconds else { return .green }
        return d > 90 ? Color(red: 1.0, green: 0.62, blue: 0.04) : .green
    }
}

/// The full Lock Screen layout: title, progress bar, and scheduled-vs-estimated arrival.
private struct LockScreenView: View {
    let context: ActivityViewContext<DriveActivityAttributes>

    private var delayColor: Color {
        guard let d = context.state.delaySeconds else { return .green }
        return d > 90 ? Color(red: 1.0, green: 0.62, blue: 0.04) : .green
    }

    private var statusText: String {
        guard let d = context.state.delaySeconds else { return "On the way" }
        let mins = max(1, abs(d) / 60)
        if d > 90 { return "\(mins) min late" }
        if d < -90 { return "\(mins) min early" }
        return "On time"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(context.attributes.tripTitle, systemImage: "car.fill")
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                if let dest = context.state.destinationName {
                    Text(dest).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            ProgressView(value: context.state.progress ?? 0).tint(delayColor)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scheduled").font(.caption2).foregroundStyle(.secondary)
                    Text(context.attributes.scheduledArrival.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                }
                Spacer()
                VStack(spacing: 1) {
                    Text(statusText).font(.caption2.weight(.bold)).foregroundStyle(delayColor)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Estimated").font(.caption2).foregroundStyle(.secondary)
                    Text(context.state.eta.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(delayColor)
                }
            }

            HStack(spacing: 14) {
                Label(String(format: "%.1f mi", context.state.milesTraveled), systemImage: "road.lanes")
                Label(String(format: "%.0f mph", context.state.currentSpeed), systemImage: "speedometer")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
