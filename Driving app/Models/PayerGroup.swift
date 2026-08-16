import Foundation
import SwiftData
import SwiftUI

/// A payer "group" — who covers a drive or fill-up's gas cost. Replaces the old fixed two-case
/// `PaidBy` enum with a user-editable list: the two built-ins (Me/Parents) are seeded once with
/// stable keys ("SELF"/"PARENTS") that match every historical record's already-stored `paidByRaw`
/// value (and the backend's already-synced `paidBy` strings), and the user can add more from
/// Settings — mirroring the Vehicles section's add/edit/remove pattern.
@Model
final class PayerGroup {
    /// Stable, wire-level identifier — this is what's actually stored in every trip/schedule/gas
    /// entry's `paidByRaw` and sent to the backend as `paidBy`. Never changes after creation, even
    /// if the user renames the group (renaming only changes `name`).
    var key: String = ""
    var name: String = ""
    var icon: String = "person.fill"
    var colorName: String = "blue"
    var sortOrder: Int = 0
    /// The two seeded groups (Me/Parents) — Settings offers no delete affordance for these.
    var isBuiltIn: Bool = false
    /// Archived (not hard-deleted) groups drop out of pickers but stay resolvable, so historical
    /// trips/entries that used this group keep showing its real name/icon/color instead of
    /// "Unknown" — hard-deleting would otherwise require snapshotting payer display data onto every
    /// historical record just to survive the group being removed later.
    var isArchived: Bool = false

    init(key: String, name: String, icon: String, colorName: String, sortOrder: Int, isBuiltIn: Bool = false) {
        self.key = key
        self.name = name
        self.icon = icon
        self.colorName = colorName
        self.sortOrder = sortOrder
        self.isBuiltIn = isBuiltIn
    }

    var color: Color { PayerGroup.color(for: colorName) }
    var display: PayerDisplay { PayerDisplay(key: key, name: name, icon: icon, colorName: colorName) }
}

/// Read-only snapshot of a payer's display attributes. Used wherever code needs to show a payer
/// without necessarily holding a live `PayerGroup` — resolving an archived/orphaned key, or data
/// mirrored over WatchConnectivity (the watch is a thin display client with no SwiftData store of
/// its own, so it always works with plain resolved strings like this, not `PayerGroup` objects).
struct PayerDisplay: Hashable, Identifiable {
    var key: String
    var name: String
    var icon: String
    var colorName: String
    var id: String { key }
    var color: Color { PayerGroup.color(for: colorName) }
}

extension PayerGroup {
    /// Built-in keys, load-bearing: every existing local record and everything already synced to the
    /// backend stores exactly these two strings in its `paidBy`/`paidByRaw` field.
    static let selfKey = "SELF"
    static let parentsKey = "PARENTS"

    /// Small closed set of preset colors a group can pick from — SwiftData can't persist `Color`
    /// directly, so (mirroring `SavedPlace.icon`'s "SF Symbol name as a String" precedent) a group
    /// stores a name into this table instead.
    static let colorPresets: [(name: String, color: Color)] = [
        ("blue", .blue), ("green", .green), ("orange", .orange), ("purple", .purple),
        ("pink", .pink), ("teal", .teal), ("red", .red), ("yellow", .yellow), ("indigo", .indigo),
    ]

    static func color(for name: String) -> Color {
        colorPresets.first { $0.name == name }?.color ?? .blue
    }

    /// Small closed set of "who" icons offered when adding/editing a group in Settings.
    static let iconPresets: [String] = [
        "person.fill", "person.2.fill", "person.3.fill", "figure.wave",
        "house.fill", "briefcase.fill", "creditcard.fill", "star.fill",
    ]

    /// Resolve a stored key against the live (including archived) group list, falling back to a
    /// neutral "Unknown" display for a key that matches nothing — so every call site can show
    /// *something* sensible instead of crashing or going blank.
    static func resolve(key: String, in groups: [PayerGroup]) -> PayerDisplay {
        groups.first { $0.key == key }?.display
            ?? PayerDisplay(key: key, name: "Unknown", icon: "questionmark.circle.fill", colorName: "red")
    }
}

/// One-time seed of the two built-in payer groups, so a fresh install (or an existing install
/// updating into this feature) always has "Me"/"Parents" available before any picker renders.
@MainActor
enum PayerGroupStore {
    private static let seedKey = "didSeedPayerGroups.v1"

    /// Mirrors `TripStore.backfillPaidBy`'s one-shot-via-`UserDefaults` pattern. Safe to call on
    /// every launch — no-ops once both built-ins exist.
    static func seedIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seedKey) else { return }
        let existing = (try? context.fetch(FetchDescriptor<PayerGroup>())) ?? []
        if !existing.contains(where: { $0.key == PayerGroup.selfKey }) {
            context.insert(PayerGroup(key: PayerGroup.selfKey, name: "Me", icon: "person.fill",
                                      colorName: "blue", sortOrder: 0, isBuiltIn: true))
        }
        if !existing.contains(where: { $0.key == PayerGroup.parentsKey }) {
            context.insert(PayerGroup(key: PayerGroup.parentsKey, name: "Parents", icon: "person.2.fill",
                                      colorName: "green", sortOrder: 1, isBuiltIn: true))
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: seedKey)
    }
}
