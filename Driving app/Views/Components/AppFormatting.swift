import SwiftUI
import UIKit

/// App-wide formatting helpers, so durations, counts, and units read consistently everywhere.
enum Fmt {
    /// Human duration: "0 min", "45 min", "1h 5m", "2h". Used by trip rows, detail, summary.
    static func duration(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        if m >= 60 {
            let h = m / 60, rem = m % 60
            return rem > 0 ? "\(h)h \(rem)m" : "\(h)h"
        }
        return "\(m) min"
    }

    /// "1 drive" / "2 drives" — pluralize a count with its noun.
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }
}

extension Int {
    /// Pluralized noun for this count, e.g. `5.things("car")` → "5 cars".
    func things(_ singular: String, _ plural: String? = nil) -> String {
        Fmt.count(self, singular, plural)
    }
}

/// Thin wrapper over UIKit haptics so key interactions feel responsive and consistent.
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
}
