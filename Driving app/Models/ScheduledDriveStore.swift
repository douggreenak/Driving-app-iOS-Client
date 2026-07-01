import Foundation
import SwiftData

/// Best-effort mirror of the local schedule to the web DB. The phone is the source of truth, so
/// this upserts every local `ScheduledDrive` (create when it has no remote id, otherwise update)
/// and then reconciles deletions by removing any remote drive that no longer exists locally.
/// The schedule is tiny, so pushing the whole set is cheap and keeps the logic simple and robust —
/// no per-mutation dirty tracking required.
enum ScheduledDriveStore {
    private static let iso = ISO8601DateFormatter()

    /// Push local scheduled drives to the backend and delete remote ones that are gone locally.
    /// Silently no-ops on network failure (retried on the next call).
    @discardableResult
    static func sync(context: ModelContext) async -> Bool {
        guard let drives = try? context.fetch(FetchDescriptor<ScheduledDrive>()) else { return false }

        // Upsert every local drive.
        for drive in drives {
            if drive.remoteID == nil {
                if let remote = try? await APIClient.createScheduledDrive(payload(for: drive)) {
                    drive.remoteID = remote.id
                    drive.synced = true
                }
            } else {
                if (try? await APIClient.updateScheduledDrive(payload(for: drive))) != nil {
                    drive.synced = true
                }
            }
        }

        // Reconcile deletes: anything on the server that no longer maps to a local drive is removed.
        // SAFETY: never do this when the local set is empty — an empty phone (fresh reinstall, or a
        // sync that fires before SwiftData has loaded) must NEVER be read as "delete every scheduled
        // drive on the server". Explicit deletes remove their own remote row directly, so guarding
        // here can't leak orphans in the normal delete-the-last-drive flow.
        guard !drives.isEmpty else {
            try? context.save()
            return true
        }
        let localRemoteIDs = Set(drives.compactMap { $0.remoteID })
        if let remote = try? await APIClient.fetchScheduledDrives() {
            for r in remote where !localRemoteIDs.contains(r.id) {
                try? await APIClient.deleteScheduledDrive(id: r.id)
            }
        }

        try? context.save()
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
            isCanceled: drive.isCanceled,
            lastStartedAt: drive.lastStartedAt.map { iso.string(from: $0) },
            lastCompletedAt: drive.lastCompletedAt.map { iso.string(from: $0) },
            skippedOccurrences: drive.skippedOccurrences.map { $0.timeIntervalSince1970 }
        )
    }
}
