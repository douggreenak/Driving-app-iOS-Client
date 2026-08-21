import SwiftUI

/// A persistent, tappable row showing the currently-tracking drive's live stats — shown docked just
/// above the tab bar (Apple Music mini-player position, via `.tabViewBottomAccessory` on `ContentView`'s
/// `TabView`) whenever a drive is minimized (`ActiveDriveController.isMinimized`), so the rest of the
/// app stays usable while a drive keeps recording. Tapping it restores the full `LiveTrackingView`.
///
/// Deliberately has NO background/shape/shadow of its own: `.tabViewBottomAccessory` already renders
/// its content on top of the system's own Liquid Glass accessory bar. An earlier version drew its own
/// `.ultraThinMaterial` capsule here, which nested one rounded-glass layer inside the system's own —
/// the two corner radii didn't match, so the seam between them showed as a visible double border/edge
/// gap. Letting the accessory's own glass show through (as Apple Music's mini player does) fixes that.
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
                    // An absolute point size, unlike every other label in this bar — it stayed frozen
                    // at 9pt while the name/stat text around it grows at larger Dynamic Type sizes,
                    // so at accessibility text sizes this becomes the only static-sized label on the
                    // whole bar. `.caption2` scales like its siblings.
                    Text("Resume")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // `children: .combine` merges the subviews into one element, but the explicit
        // `.accessibilityLabel` below then REPLACES that combined label rather than adding to it —
        // so a fixed "Resume tracking drive" was all VoiceOver ever announced. This is the app's only
        // persistent surface for an in-progress drive while on another tab; build the label from the
        // same values actually on screen so a VoiceOver user can hear how the drive is going without
        // first reopening the full screen.
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Reopens the live tracking screen")
    }

    private var accessibilityLabel: String {
        var parts = [tracker.tripName ?? tracker.finalDestinationName ?? tracker.destinationName ?? "Tracking drive"]
        parts.append(String(format: "%.1f miles", tracker.distanceMiles))
        parts.append(tracker.formattedElapsed())
        if let eta = tracker.etaDate {
            parts.append("ETA \(eta.formatted(.dateTime.hour().minute()))")
        }
        if let delay = tracker.delaySeconds {
            parts.append(TripStatus.live(delaySeconds: delay).headline.capitalized)
        }
        return parts.joined(separator: ", ")
    }
}
