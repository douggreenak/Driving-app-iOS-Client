import SwiftUI

/// A persistent, tappable pill showing the currently-tracking drive's live stats — shown docked just
/// above the tab bar (Apple Music mini-player position) whenever a drive is minimized
/// (`ActiveDriveController.isMinimized`), so the rest of the app stays usable while a drive keeps
/// recording. Tapping it restores the full `LiveTrackingView`.
struct MinimizedDriveBar: View {
    let tracker: LocationTracker
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.green.gradient, in: .circle)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tracker.tripName ?? tracker.finalDestinationName ?? tracker.destinationName ?? "Tracking")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(String(format: "%.1f mi", tracker.distanceMiles))
                        Text("·")
                        Text(tracker.formattedElapsed())
                        if let eta = tracker.etaDate {
                            Text("·")
                            Text("ETA \(eta.formatted(.dateTime.hour().minute()))")
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer(minLength: 8)

                if tracker.scheduledArrival != nil {
                    if let delay = tracker.delaySeconds {
                        StatusChip(status: .live(delaySeconds: delay), compact: true)
                    } else {
                        StatusChip(status: .liveEnRoute, compact: true)
                    }
                }

                VStack(spacing: 1) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                    Text("Resume")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resume tracking drive")
        .accessibilityHint("Reopens the live tracking screen")
    }
}
