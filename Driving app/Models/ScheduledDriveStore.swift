import Foundation
import SwiftData

/// Bidirectional mirror between the local schedule and the web DB: upserts every local
/// `ScheduledDrive` (create when it has no remote id, otherwise update), PULLS IN any remote drive
/// that doesn't exist locally yet (added from the web dashboard or another device), and reconciles
/// genuine deletions — a remote drive that's still missing locally *after* the pull, and isn't one
/// this device just deleted itself, is treated as removed elsewhere and dropped locally too; a
/// remote drive this device deleted while offline (recorded in `deletedRemoteIDs` at delete time,
/// since the live `APIClient.deleteScheduledDrive` call at the point of deletion can't be trusted to
/// have reached the server) is deleted remotely on this pass instead of being resurrected by the pull.
/// The schedule is tiny, so pushing/pulling the whole set is cheap and keeps the logic simple and
/// robust — no per-mutation dirty tracking required.
///
/// Before this pulled anything, "remote row with no local match" was assumed to always mean
/// "deleted locally, clean up the server" — which is only true for THIS device's own offline
/// deletes. A drive added on the web dashboard or another device looks identical (a remote id the
/// phone has never seen), so the old logic silently deleted it from the server the next time this
/// phone synced. The tombstone is what makes "pull it in" vs. "it's a deletion to propagate" safe to
/// tell apart.
// @MainActor: the ModelContext passed in is the main-actor `@Environment(\.modelContext)`. A
// non-isolated async function would run `context.fetch`/mutations on the cooperative pool across
// `await` network hops — using a ModelContext off its owning thread can crash or corrupt the store.
@MainActor
enum ScheduledDriveStore {
    private static let iso = ISO8601DateFormatter()

    // MARK: - Tombstone (this device's own deletes, pending remote confirmation)

    private static let tombstoneKey = "ScheduledDriveStore.deletedRemoteIDs.v1"
    /// How long a tombstone is honored before it's pruned — long enough to survive an extended
    /// offline stretch, short enough that a stale entry can't wrongly suppress a pull forever.
    private static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

    /// Record that THIS device deleted a synced scheduled drive, so a sync before the matching
    /// `APIClient.deleteScheduledDrive` call reaches the server (offline, or racing this sync) can't
    /// have the pull step below resurrect it. Call this at the same point the local delete happens.
    static func recordLocalDeletion(remoteID: String) {
        var entries = tombstones()
        entries[remoteID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(entries, forKey: tombstoneKey)
    }

    private static func tombstones() -> [String: TimeInterval] {
        let raw = (UserDefaults.standard.dictionary(forKey: tombstoneKey) as? [String: TimeInterval]) ?? [:]
        let cutoff = Date().timeIntervalSince1970 - tombstoneLifetime
        return raw.filter { $0.value >= cutoff }
    }

    private static func clearTombstone(_ remoteID: String) {
        var entries = tombstones()
        entries.removeValue(forKey: remoteID)
        UserDefaults.standard.set(entries, forKey: tombstoneKey)
    }

    // Coalesce concurrent syncs. sync() is fired from many sites (list .task/.refreshable, save,
    // cancel, delete, detail page). Two overlapping runs would each POST the same remoteID==nil
    // drive (duplicate rows) and each reconcile against a stale local-id snapshot (deleting the
    // other run's fresh row). A single in-flight flag with a "run again after" latch serializes them.
    private static var isSyncing = false
    private static var rerunRequested = false

    /// Push local scheduled drives to the backend and delete remote ones that are gone locally.
    /// Silently no-ops on network failure (retried on the next call). Concurrent calls coalesce.
    @discardableResult
    static func sync(context: ModelContext) async -> Bool {
        if isSyncing { rerunRequested = true; return false }
        isSyncing = true
        defer { isSyncing = false }
        let ok = await runSync(context: context)
        // Drain: keep running passes as long as mutations landed during the previous one, so the
        // final reconcile always sees the true final state (a single `if` would strand a change
        // whose sync() fired during the rerun pass until some unrelated future call consumed it).
        while rerunRequested {
            rerunRequested = false
            _ = await runSync(context: context)
        }
        return ok
    }

    private static func runSync(context: ModelContext) async -> Bool {
        guard let drives = try? context.fetch(FetchDescriptor<ScheduledDrive>()) else { return false }

        // Upsert every local drive. Track whether every upsert succeeded — a failed create/update
        // must NOT let the reconcile pass delete rows it simply couldn't confirm this run.
        var allUpsertsSucceeded = true
        for drive in drives {
            if drive.remoteID == nil {
                if let remote = try? await APIClient.createScheduledDrive(payload(for: drive)) {
                    drive.remoteID = remote.id
                    drive.synced = true
                } else {
                    allUpsertsSucceeded = false
                }
            } else {
                if (try? await APIClient.updateScheduledDrive(payload(for: drive))) != nil {
                    drive.synced = true
                } else {
                    allUpsertsSucceeded = false
                }
            }
        }
        try? context.save()

        // Never touch anything below when an upsert failed this run: a just-created row on another
        // device could look "not local yet" for the wrong reason, and skipping keeps this pass from
        // reconciling against a set it isn't confident reflects the true local state.
        guard allUpsertsSucceeded else { return true }
        guard let remote = try? await APIClient.fetchScheduledDrives() else { return true }

        // Re-read local remoteIDs right before reconciling so the upserts above (and anything a
        // concurrent, coalesced sync landed) are reflected.
        let current = (try? context.fetch(FetchDescriptor<ScheduledDrive>())) ?? drives
        let localRemoteIDs = Set(current.compactMap { $0.remoteID })
        let tombstoned = tombstones()

        // Pull in anything on the server this device has never seen — added from the web dashboard
        // or another device — UNLESS this device deleted it itself and is just waiting to confirm
        // that with the server (below); pulling it back in would silently undo the user's delete.
        var pulledAny = false
        for r in remote where !localRemoteIDs.contains(r.id) && tombstoned[r.id] == nil {
            insertLocal(from: r, context: context)
            pulledAny = true
        }
        if pulledAny { try? context.save() }

        // Reconcile genuine deletions: never when the local set was empty before this run (a fresh
        // reinstall must not wipe the server) — but a drive still missing after the pull above is now
        // either something this device deleted (tombstoned — retry the remote delete it may have
        // missed while offline) or removed on the server by some other means; either way, dropping
        // its local copy (should it exist) and confirming the remote delete is correct here.
        guard !drives.isEmpty else { return true }
        for r in remote where !localRemoteIDs.contains(r.id) && tombstoned[r.id] != nil {
            try? await APIClient.deleteScheduledDrive(id: r.id)
            clearTombstone(r.id)
        }
        return true
    }

    /// Build a local `ScheduledDrive` from a remote row this device has never seen and insert it —
    /// the pull half of `runSync`'s reconcile pass.
    private static func insertLocal(from r: APIScheduledDrive, context: ModelContext) {
        guard let departure = iso.date(from: r.departure), let arrival = iso.date(from: r.scheduledArrival) else { return }
        let drive = ScheduledDrive(
            title: r.title, startAddress: r.startAddress, endAddress: r.endAddress,
            startLat: r.startLat, startLng: r.startLng, endLat: r.endLat, endLng: r.endLng,
            departure: departure, estimatedTravelTime: r.estimatedTravelTime, scheduledArrival: arrival,
            repeatRule: RepeatRule(rawValue: r.repeatRule) ?? .none,
            category: TripCategory(rawValue: r.category) ?? .commute,
            paidBy: r.paidBy, vehicleName: r.vehicleName, notes: r.notes, isEnabled: r.isEnabled
        )
        drive.remoteID = r.id
        drive.synced = true
        drive.stops = r.stops ?? []
        drive.lastStartedAt = r.lastStartedAt.flatMap { iso.date(from: $0) }
        drive.lastCompletedAt = r.lastCompletedAt.flatMap { iso.date(from: $0) }
        drive.skippedOccurrences = r.skippedOccurrences.map { Date(timeIntervalSince1970: $0) }
        context.insert(drive)
    }

    private static func payload(for drive: ScheduledDrive) -> APIScheduledDrivePayload {
        APIScheduledDrivePayload(
            id: drive.remoteID,
            title: drive.title,
            startAddress: drive.startAddress,
            endAddress: drive.endAddress,
            startLat: drive.startLat, startLng: drive.startLng,
            endLat: drive.endLat, endLng: drive.endLng,
            departure: iso.string(from: drive.departure),
            estimatedTravelTime: drive.estimatedTravelTime,
            scheduledArrival: iso.string(from: drive.scheduledArrival),
            repeatRule: drive.repeatRuleRaw,
            category: drive.categoryRaw,
            paidBy: drive.paidByRaw,
            vehicleName: drive.vehicleName,
            notes: drive.notes,
            isEnabled: drive.isEnabled,
            // Whole-series cancel was retired for per-occurrence cancellation; always send false so
            // any drive previously canceled server-side is cleared on the next sync.
            isCanceled: false,
            lastStartedAt: drive.lastStartedAt.map { iso.string(from: $0) },
            lastCompletedAt: drive.lastCompletedAt.map { iso.string(from: $0) },
            skippedOccurrences: drive.skippedOccurrences.map { $0.timeIntervalSince1970 },
            canceledOccurrences: drive.canceledOccurrences.map { $0.timeIntervalSince1970 },
            stops: drive.stops
        )
    }
}
