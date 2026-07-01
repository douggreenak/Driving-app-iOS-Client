import SwiftUI

extension PaidBy {
    /// Color used everywhere the payer is shown — parents (green) vs me (blue).
    var tint: Color { self == .parents ? .green : .blue }
}

extension Color {
    /// Delayed / late status. A vivid amber that reads brightly on the dark UI and stays
    /// clearly distinct from the canceled red and the on-time green (plain system orange
    /// looked muddy on black and sat too close to red).
    static let statusDelay = Color(red: 1.0, green: 0.62, blue: 0.04)
}

/// A small filled chip showing who pays for a drive's gas.
struct PayerChip: View {
    let payer: PaidBy
    var compact: Bool = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: payer.icon)
            Text(payer.label)
        }
        .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, compact ? 7 : 9).padding(.vertical, compact ? 3 : 5)
        .background(payer.tint, in: .capsule)
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Paid by \(payer.label)")
    }
}

/// A flight-board-style schedule status: On Time / Early / Delayed / Canceled / Scheduled.
/// Drives the prominent, color-coded status indicators across the app.
struct TripStatus {
    enum Kind { case onTime, early, delayed, canceled, scheduled, none }

    let kind: Kind
    let headline: String
    let detail: String?
    let color: Color
    let icon: String

    /// On-time tolerance: within ±90s counts as on time.
    private static let tolerance = 90

    /// Formats a minute count, switching to hours past 60 (e.g. 45 → "45 min", 90 → "1h 30m").
    static func delayLabel(minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes) min"
    }

    /// Status for a completed trip given how late it arrived (positive = late).
    static func forTrip(delaySeconds: Int?) -> TripStatus {
        guard let d = delaySeconds else {
            return .init(kind: .none, headline: "UNSCHEDULED", detail: "Not linked to a schedule",
                         color: .secondary, icon: "calendar.badge.minus")
        }
        let mins = max(1, abs(d) / 60)
        if d > tolerance {
            return .init(kind: .delayed, headline: "DELAYED", detail: "\(delayLabel(minutes: mins)) behind schedule",
                         color: .statusDelay, icon: "clock.fill")
        } else if d < -tolerance {
            return .init(kind: .early, headline: "EARLY", detail: "\(delayLabel(minutes: mins)) ahead of schedule",
                         color: .green, icon: "checkmark.seal.fill")
        }
        return .init(kind: .onTime, headline: "ON TIME", detail: "Arrived as scheduled",
                     color: .green, icon: "checkmark.seal.fill")
    }

    /// Live status while driving toward a scheduled arrival (positive = projected late).
    static func live(delaySeconds: Int?) -> TripStatus {
        guard let d = delaySeconds else {
            return .init(kind: .none, headline: "NO SCHEDULE", detail: nil, color: .gray, icon: "minus.circle.fill")
        }
        let mins = max(1, abs(d) / 60)
        if d > tolerance {
            return .init(kind: .delayed, headline: "DELAYED", detail: "\(delayLabel(minutes: mins)) behind",
                         color: .statusDelay, icon: "clock.fill")
        } else if d < -tolerance {
            return .init(kind: .early, headline: "AHEAD", detail: "\(delayLabel(minutes: mins)) early",
                         color: .green, icon: "checkmark.seal.fill")
        }
        return .init(kind: .onTime, headline: "ON TIME", detail: "Right on schedule",
                     color: .green, icon: "checkmark.seal.fill")
    }

    /// Status for an upcoming scheduled drive.
    static func scheduled(isCanceled: Bool) -> TripStatus {
        isCanceled
            ? .init(kind: .canceled, headline: "CANCELED", detail: nil, color: .red, icon: "xmark.octagon.fill")
            : .init(kind: .scheduled, headline: "SCHEDULED", detail: nil, color: .blue, icon: "calendar")
    }

    /// Color-coded status for a scheduled drive, based on comparing the projected arrival to the
    /// scheduled arrival (`delaySeconds` = estimated arrival − scheduled arrival; positive = late).
    static func upcoming(delaySeconds: Int, isCanceled: Bool) -> TripStatus {
        if isCanceled {
            return .init(kind: .canceled, headline: "CANCELED", detail: nil, color: .red, icon: "xmark.octagon.fill")
        }
        let mins = max(1, abs(delaySeconds) / 60)
        if delaySeconds > tolerance {
            return .init(kind: .delayed, headline: "DELAYED", detail: "Arriving ~\(delayLabel(minutes: mins)) late",
                         color: .statusDelay, icon: "clock.fill")
        } else if delaySeconds < -tolerance {
            return .init(kind: .early, headline: "EARLY", detail: "Arriving ~\(delayLabel(minutes: mins)) early",
                         color: .green, icon: "checkmark.seal.fill")
        }
        return .init(kind: .onTime, headline: "ON TIME", detail: "Arriving on schedule",
                     color: .green, icon: "checkmark.seal.fill")
    }

    static var departed: TripStatus {
        .init(kind: .onTime, headline: "DEPARTED", detail: nil, color: .gray, icon: "checkmark.circle.fill")
    }

    /// Status for a single departures-board occurrence (also used by the scheduled-detail page).
    /// Follows the product spec: an upcoming drive is ON TIME (green) until its departure time;
    /// once departure passes with no recorded start it becomes LATE (orange); a start in the
    /// window marks it DEPARTED; canceled wins over everything.
    static func occurrence(departure: Date, scheduledArrival: Date, travelSeconds: Int,
                           isCanceled: Bool, startedAt: Date?, now: Date = .now) -> TripStatus {
        if isCanceled {
            return .init(kind: .canceled, headline: "CANCELED", detail: nil, color: .red, icon: "xmark.octagon.fill")
        }
        // Driven? A recorded start near this occurrence's window marks it departed.
        if let startedAt,
           startedAt >= departure.addingTimeInterval(-1800),
           startedAt <= scheduledArrival.addingTimeInterval(3 * 3600) {
            return departed
        }
        // Still before departure → on time, with a friendly countdown.
        if now < departure {
            return .init(kind: .onTime, headline: "ON TIME", detail: countdown(to: departure, from: now),
                         color: .green, icon: "checkmark.seal.fill")
        }
        // Departure time has passed without a recorded start → late to leave.
        let lateMins = max(1, Int(now.timeIntervalSince(departure)) / 60)
        return .init(kind: .delayed, headline: "LATE", detail: "\(delayLabel(minutes: lateMins)) past departure",
                     color: .statusDelay, icon: "clock.fill")
    }

    /// "in 3h 20m" / "20m ago" relative to a departure time.
    static func countdown(to date: Date, from now: Date = .now) -> String {
        let secs = Int(date.timeIntervalSince(now))
        let mins = abs(secs) / 60
        let h = mins / 60, m = mins % 60
        let body = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return secs >= 0 ? "in \(body)" : "\(body) ago"
    }
}

/// Big, unmissable status banner (used on the trip detail page).
struct StatusBanner: View {
    let status: TripStatus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: status.icon)
                .font(.title.weight(.bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline)
                    .font(.title2.weight(.heavy))
                    .tracking(0.5)
                if let detail = status.detail {
                    Text(detail).font(.subheadline.weight(.medium)).opacity(0.95)
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.color.gradient, in: .rect(cornerRadius: 16))
        .shadow(color: status.color.opacity(0.35), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.detail.map { "\(status.headline). \($0)" } ?? status.headline)
    }
}

/// Compact, filled status chip (used in lists and the live HUD).
struct StatusChip: View {
    let status: TripStatus
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
            Text(status.headline)
        }
        .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(status.color, in: .capsule)
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel(status.detail.map { "\(status.headline). \($0)" } ?? status.headline)
    }
}
