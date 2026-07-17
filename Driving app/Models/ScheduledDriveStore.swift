import Foundation
import SwiftData

/// Best-effort mirror of the local schedule to the web DB. The phone is the source of truth, so
/// this upserts every local `ScheduledDrive` (create when it has no remote id, otherwise update)
/// and then reconciles deletions by removing any remote drive that no longer exists locally.
/// The schedule is tiny, so pushing the whole set is cheap and keeps the logic simple and robust —
/// no per-mutation dirty tracking required.
// @MainActor: the ModelContext passed in is the main-actor `@Environment(\.modelContext)`. A
// non-isolated async function would run `context.fetch`/mutations on the cooperative pool across
// `await` network hops — using a ModelContext off its owning thread can crash or corrupt the store.
@MainActor
enum ScheduledDriveStore {
    private static let iso = ISO8601DateFormatter()

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

        // Reconcile deletes: anything on the server that no longer maps to a local drive is removed.
        // SAFETY: never when the local set is empty (fresh reinstall must not wipe the server), and
        // never when an upsert failed this run (a just-created row on another device could look
        // "not local" and be deleted). Re-read local remoteIDs right before reconciling so creates
        // performed above are reflected.
        guard !drives.isEmpty, allUpsertsSucceeded else { return true }
        let current = (try? context.fetch(FetchDescriptor<ScheduledDrive>())) ?? drives
        let localRemoteIDs = Set(current.compactMap { $0.remoteID })
        if let remote = try? await APIClient.fetchScheduledDrives() {
            for r in remote where !localRemoteIDs.contains(r.id) {
                try? await APIClient.deleteScheduledDrive(id: r.id)
            }
        }
        return true
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
