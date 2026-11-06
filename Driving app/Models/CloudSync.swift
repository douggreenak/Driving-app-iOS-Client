import Foundation
import SwiftData
import CoreLocation
import Observation

// MARK: - Status (observed by Settings)

/// What the cloud-sync engine is doing / did last, shown in Settings → Cloud Sync.
@Observable
@MainActor
final class CloudSyncStatus {
    static let shared = CloudSyncStatus()
    var isRunning = false
    var lastRun: Date?
    /// Nil when the last run completed cleanly.
    var lastError: String?
    var step = ""
    var remoteTripTotal = 0
    var tripsRestoredThisRun = 0
    var pointsRestoredTrips = 0
    var pendingPointDownloads = 0
    var pendingUploads = 0
}

// MARK: - Wire models (mirror the backend's Prisma models)

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
private let isoPlain = ISO8601DateFormatter()
private func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}
private func stamp(_ d: Date) -> String { isoPlain.string(from: d) }

struct RemoteTripFull: Decodable {
    let id: String
    let date: String
    let endDate: String?
    let startAddress: String
    let endAddress: String
    let startLat: Double, startLng: Double, endLat: Double, endLng: Double
    let distance: Double
    let duration: Int
    let movingSeconds: Int?
    let maxSpeed: Double?
    let avgSpeed: Double?
    let notes: String?
    let name: String?
    let routeEncoded: String?
    let matchedPolyline: String?
    let matchedFraction: Double?
    let usedRouteMatching: Bool?
    let category: String?
    let isFavorite: Bool?
    let paidBy: String?
    let vehicleName: String?
    let vehicleMpg: Double?
    let estimatedGallons: Double?
    let scheduledDeparture: String?
    let scheduledArrival: String?
    let journeyId: String?
    let legIndex: Int?
    let legTotal: Int?
    let isManualEntry: Bool?
    let stops: [RouteStop]?
}

private struct RemoteTripsPage: Decodable { let items: [RemoteTripFull]; let total: Int }

struct RemotePoint: Codable {
    let seq: Int
    let t: String
    let lat: Double, lng: Double, speed: Double, course: Double, accuracy: Double, altitude: Double
    let onRoad: Bool
}

private struct RemoteVehicle: Codable {
    var id: String?
    let name: String
    let make: String?, model: String?
    let year: Int?
    let tankSize: Double?, avgMpg: Double?
    let lastFilledUp: String?
}

private struct RemotePayer: Codable {
    let key: String, name: String, icon: String, colorName: String
    let sortOrder: Int, isBuiltIn: Bool, isArchived: Bool
}

private struct RemotePlace: Codable {
    var id: String?
    let label: String, address: String
    let lat: Double, lng: Double
    let icon: String, sortOrder: Int
}

private struct RemoteSettingsEnvelope: Decodable {
    struct S: Decodable {
        let monthlyBudget: Double?, distanceUnit: String?, fuelPricePerGallon: Double?, defaultPaidBy: String?
    }
    let settings: S
}

// MARK: - Engine

/// Mirrors the phone's data to the web backend and — crucially — **restores** from it: anything the
/// cloud has that this device doesn't (a fresh install, a re-signed build) is pulled back down.
///
/// Rules (the data is irreplaceable, so these are non-negotiable):
///  • ADDITIVE ONLY. Nothing local is ever deleted or overwritten by a pull; remote rows are only
///    inserted when no local match exists. Local-only rows are pushed up.
///  • Settings are pulled ONCE (so a fresh install can't overwrite the real cloud settings with
///    defaults); after that the phone is the source of truth and pushes.
///  • A failed step never aborts the others and never discards anything.
@MainActor
enum CloudSync {
    private static var running = false
    private static var lastStart = Date.distantPast
    private static let settingsPulledKey = "cloud.settingsPulled.v1"
    private static let noRemotePointsKey = "cloud.noRemotePoints.v1"
    private static let pendingPointUploadsKey = "cloud.pendingPointUploads.v1"
    private static var status: CloudSyncStatus { .shared }

    // MARK: Entry point

    /// Run a full sync pass. `force` bypasses the 60 s throttle; `deep` also downloads every
    /// missing track (otherwise a limited batch per pass, plus on-demand when a trip is opened).
    static func run(context: ModelContext, force: Bool = false, deep: Bool = false) async {
        // Unstructured on purpose: callers invoke this from `.task(id:)` blocks, which SwiftUI cancels
        // the moment the id changes (every tab switch). A cancelled sync used to abort mid-request
        // ("cancelled") and, with the throttle below, then sat idle for a minute. Awaiting the
        // unstructured task's value lets the caller wait without a cancellation ever reaching it.
        await Task { @MainActor in await perform(context: context, force: force, deep: deep) }.value
    }

    private static func perform(context: ModelContext, force: Bool, deep: Bool) async {
        guard !running else { return }
        if !force, Date().timeIntervalSince(lastStart) < 60 { return }
        running = true; lastStart = Date()
        status.isRunning = true; status.lastError = nil; status.tripsRestoredThisRun = 0
        defer { running = false; status.isRunning = false; status.lastRun = Date(); status.step = "" }

        var firstError: String?
        func step(_ name: String, _ work: () async throws -> Void) async {
            status.step = name
            do { try await work() } catch { if firstError == nil { firstError = describe(error, step: name) } }
        }

        await step("Payer groups") { try await syncPayerGroups(context) }
        await step("Vehicles") { try await syncVehicles(context) }
        await step("Saved places") { try await syncPlaces(context) }
        await step("Settings") { try await syncSettings(context) }
        await step("Restoring trips") { try await restoreTrips(context) }
        await step("Uploading trips") { _ = await TripStore.syncPending(context: context) }
        await step("Uploading tracks") { await flushPendingPointUploads(context) }
        await step("Restoring tracks") { await restoreMissingPoints(context, limit: deep ? .max : 12) }

        status.lastError = firstError
    }

    private static func describe(_ error: Error, step: String) -> String {
        if let e = error as? APIClient.APIError {
            switch e {
            case .http(401): return "\(step): the server rejected the API key (401). Rebuild with the correct key."
            case .http(let c): return "\(step): server error \(c)."
            case .writeBlockedInDebug: return "\(step): live-server writes are blocked in simulator debug builds."
            }
        }
        return "\(step): \(error.localizedDescription)"
    }

    // MARK: JSON helpers

    private static func getJSON<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await APIClient.get(path))
    }
    private static func send<B: Encodable>(_ method: String, _ path: String, _ body: B) async throws {
        _ = try await APIClient.request(method, path, body: try JSONEncoder().encode(body))
    }

    // MARK: Payer groups

    private static func syncPayerGroups(_ ctx: ModelContext) async throws {
        let remote: [RemotePayer] = try await getJSON("/api/payer-groups")
        let local = (try? ctx.fetch(FetchDescriptor<PayerGroup>())) ?? []
        let localKeys = Set(local.map(\.key)), remoteKeys = Set(remote.map(\.key))
        for r in remote where !localKeys.contains(r.key) {
            let g = PayerGroup(key: r.key, name: r.name, icon: r.icon, colorName: r.colorName,
                               sortOrder: r.sortOrder, isBuiltIn: r.isBuiltIn)
            g.isArchived = r.isArchived
            ctx.insert(g)
        }
        try? ctx.save()
        for l in local where !remoteKeys.contains(l.key) {
            try await send("POST", "/api/payer-groups", RemotePayer(
                key: l.key, name: l.name, icon: l.icon, colorName: l.colorName,
                sortOrder: l.sortOrder, isBuiltIn: l.isBuiltIn, isArchived: l.isArchived))
        }
    }

    // MARK: Vehicles

    private static func syncVehicles(_ ctx: ModelContext) async throws {
        let remote: [RemoteVehicle] = try await getJSON("/api/vehicles")
        let local = (try? ctx.fetch(FetchDescriptor<Vehicle>())) ?? []
        func k(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        var localByName = Dictionary(local.map { (k($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        let remoteNames = Set(remote.map { k($0.name) })

        for r in remote {
            if let l = localByName[k(r.name)] {
                // Fill only what's missing locally — never overwrite what the user has set.
                if l.make == nil { l.make = r.make }
                if l.model == nil { l.model = r.model }
                if l.year == nil { l.year = r.year }
                if l.tankSize == nil { l.tankSize = r.tankSize }
                if l.avgMpg == nil { l.avgMpg = r.avgMpg }
                if l.lastFilledUp == nil { l.lastFilledUp = parseDate(r.lastFilledUp) }
            } else {
                let v = Vehicle(name: r.name, make: r.make, model: r.model, year: r.year,
                                tankSize: r.tankSize, avgMpg: r.avgMpg)
                v.lastFilledUp = parseDate(r.lastFilledUp)
                ctx.insert(v)
                localByName[k(r.name)] = v
            }
        }
        try? ctx.save()

        for l in local where !remoteNames.contains(k(l.name)) {
            try await send("POST", "/api/vehicles", RemoteVehicle(
                id: nil, name: l.name, make: l.make, model: l.model, year: l.year, tankSize: l.tankSize,
                avgMpg: l.avgMpg, lastFilledUp: l.lastFilledUp.map(stamp)))
        }
        // Keep the cloud copy's MPG/fill-up date in step when the phone changed them.
        for r in remote {
            guard let id = r.id, let l = localByName[k(r.name)] else { continue }
            let lf = l.lastFilledUp.map(stamp), rf = parseDate(r.lastFilledUp).map(stamp)
            if (l.avgMpg != nil && l.avgMpg != r.avgMpg) || (lf != nil && lf != rf) {
                try await send("PATCH", "/api/vehicles", RemoteVehicle(
                    id: id, name: l.name, make: l.make, model: l.model, year: l.year,
                    tankSize: l.tankSize, avgMpg: l.avgMpg, lastFilledUp: lf))
            }
        }
    }

    // MARK: Saved places

    private static func syncPlaces(_ ctx: ModelContext) async throws {
        let remote: [RemotePlace] = try await getJSON("/api/saved-places")
        let local = (try? ctx.fetch(FetchDescriptor<SavedPlace>())) ?? []
        func k(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        let localKeys = Set(local.map { k($0.label) }), remoteKeys = Set(remote.map { k($0.label) })
        for r in remote where !localKeys.contains(k(r.label)) {
            ctx.insert(SavedPlace(label: r.label, address: r.address, lat: r.lat, lng: r.lng,
                                  icon: r.icon, sortOrder: r.sortOrder))
        }
        try? ctx.save()
        for l in local where !remoteKeys.contains(k(l.label)) {
            try await send("POST", "/api/saved-places", RemotePlace(
                id: nil, label: l.label, address: l.address, lat: l.lat, lng: l.lng,
                icon: l.icon, sortOrder: l.sortOrder))
        }
    }

    // MARK: Settings

    private struct SettingsPush: Encodable {
        let monthlyBudget: Double, distanceUnit: String, fuelPricePerGallon: Double, defaultPaidBy: String
    }

    private static func syncSettings(_ ctx: ModelContext) async throws {
        guard let local = (try? ctx.fetch(FetchDescriptor<UserSettings>()))?.first else { return }
        if !UserDefaults.standard.bool(forKey: settingsPulledKey) {
            let env: RemoteSettingsEnvelope = try await getJSON("/api/settings")
            let s = env.settings
            if let v = s.monthlyBudget { local.monthlyBudget = v }
            if let v = s.distanceUnit { local.distanceUnit = v }
            if let v = s.fuelPricePerGallon { local.fuelPricePerGallon = v }
            if let v = s.defaultPaidBy { local.defaultPaidByRaw = v }
            try? ctx.save()
            UserDefaults.standard.set(true, forKey: settingsPulledKey)
            return
        }
        try await send("PUT", "/api/settings", SettingsPush(
            monthlyBudget: local.monthlyBudget, distanceUnit: local.distanceUnit,
            fuelPricePerGallon: local.fuelPricePerGallon, defaultPaidBy: local.defaultPaidByRaw))
    }

    // MARK: Trips — restore

    private static func restoreTrips(_ ctx: ModelContext) async throws {
        // Cheap probe first: the total, without any bulky columns.
        struct Probe: Decodable { let total: Int }
        let probe: Probe = try await getJSON("/api/trips?page=1&pageSize=1")
        status.remoteTripTotal = probe.total

        let local = (try? ctx.fetch(FetchDescriptor<DriveTrip>())) ?? []
        var knownRemote = Set(local.compactMap(\.remoteID))
        let missing = probe.total - knownRemote.count
        guard missing > 0 else { return }

        // Local trips that never got a remote id but ARE on the server (an upload that succeeded
        // but wasn't recorded) are linked instead of duplicated.
        func key(_ d: Date, _ lat: Double, _ lng: Double) -> String {
            "\(Int(d.timeIntervalSince1970 / 5))|\(Int(lat * 1000))|\(Int(lng * 1000))"
        }
        var unlinked = Dictionary(local.filter { $0.remoteID == nil }.map { (key($0.date, $0.startLat, $0.startLng), $0) },
                                  uniquingKeysWith: { a, _ in a })
        var journeyIDs: [String: UUID] = [:]
        var inserted = 0, page = 1
        while inserted < missing {
            let result: RemoteTripsPage = try await getJSON("/api/trips?full=true&page=\(page)&pageSize=20")
            if result.items.isEmpty { break }
            for r in result.items where !knownRemote.contains(r.id) {
                guard let date = parseDate(r.date) else { continue }
                if let dup = unlinked[key(date, r.startLat, r.startLng)] {
                    dup.remoteID = r.id; dup.synced = true
                    unlinked[key(date, r.startLat, r.startLng)] = nil
                    knownRemote.insert(r.id); inserted += 1
                    continue
                }
                insertTrip(r, date: date, journeyIDs: &journeyIDs, into: ctx)
                knownRemote.insert(r.id); inserted += 1
                status.tripsRestoredThisRun += 1
            }
            try? ctx.save()
            page += 1
            await Task.yield()
        }
        status.pendingPointDownloads = max(0, status.pendingPointDownloads)
        recomputeLayovers(ctx)
    }

    private static func insertTrip(_ r: RemoteTripFull, date: Date, journeyIDs: inout [String: UUID],
                                   into ctx: ModelContext) {
        let end = parseDate(r.endDate) ?? date.addingTimeInterval(TimeInterval(r.duration * 60))
        let seconds = max(r.duration * 60, Int(end.timeIntervalSince(date)))
        let poly: Data? = r.matchedPolyline.flatMap { Data(base64Encoded: $0) }
        let trip = DriveTrip(
            date: date, endDate: end,
            startAddress: r.startAddress, endAddress: r.endAddress,
            startLat: r.startLat, startLng: r.startLng, endLat: r.endLat, endLng: r.endLng,
            distance: r.distance, duration: seconds,
            movingSeconds: r.movingSeconds ?? 0, maxSpeed: r.maxSpeed ?? 0, avgSpeed: r.avgSpeed ?? 0,
            notes: r.notes, name: r.name,
            category: TripCategory(rawValue: r.category ?? "") ?? .other,
            isFavorite: r.isFavorite ?? false, paidBy: r.paidBy ?? PayerGroup.selfKey,
            vehicleName: r.vehicleName, vehicleMpg: r.vehicleMpg,
            estimatedGallons: r.estimatedGallons ?? 0,
            scheduledDeparture: parseDate(r.scheduledDeparture), scheduledArrival: parseDate(r.scheduledArrival),
            matchedFraction: r.matchedFraction ?? 0, usedRouteMatching: r.usedRouteMatching ?? false,
            matchedPolyline: poly, isManualEntry: r.isManualEntry ?? false)
        trip.stops = r.stops ?? []
        if let j = r.journeyId, !j.isEmpty {
            let uuid = UUID(uuidString: j) ?? journeyIDs[j] ?? UUID()
            journeyIDs[j] = uuid
            trip.journeyID = uuid
        }
        trip.legIndex = r.legIndex ?? 0
        trip.legTotal = r.legTotal ?? 1
        trip.remoteID = r.id
        trip.synced = true
        // Without a stored snapped route, fall back to the lightweight encoded polyline for display.
        if poly == nil, let enc = r.routeEncoded, !enc.isEmpty {
            let coords = decodePolyline(enc)
            trip.matchedPolyline = try? JSONEncoder().encode(coords.map { [$0.latitude, $0.longitude] })
        }
        ctx.insert(trip)
    }

    /// Connection time for restored journey legs = gap since the previous leg ended.
    private static func recomputeLayovers(_ ctx: ModelContext) {
        guard let all = try? ctx.fetch(FetchDescriptor<DriveTrip>(
            predicate: #Predicate { $0.journeyID != nil }, sortBy: [SortDescriptor(\.date)])) else { return }
        let groups = Dictionary(grouping: all, by: { $0.journeyID! })
        for (_, legs) in groups {
            let ordered = legs.sorted { $0.legIndex < $1.legIndex }
            for (i, t) in ordered.enumerated() where t.layoverSeconds == 0 && i > 0 {
                t.layoverSeconds = max(0, Int(t.date.timeIntervalSince(ordered[i - 1].endDate)))
            }
        }
        try? ctx.save()
    }

    // MARK: Track points — restore

    private static func set(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
    private static func store(_ s: Set<String>, _ key: String) {
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    /// Download one trip's track from the cloud (used on demand when a trip is opened, and in batches).
    @discardableResult
    static func restorePoints(for trip: DriveTrip) async -> Bool {
        guard let rid = trip.remoteID, trip.points.isEmpty, !trip.isManualEntry,
              let ctx = trip.modelContext else { return false }
        var none = set(noRemotePointsKey)
        if none.contains(rid) { return false }
        guard let pts = try? await getJSON("/api/trips/\(rid)/points", as: [RemotePoint].self) else { return false }
        guard pts.count >= 2 else { none.insert(rid); store(none, noRemotePointsKey); return false }
        for p in pts {
            let tp = TrackPoint(seq: p.seq, t: parseDate(p.t) ?? trip.date, lat: p.lat, lng: p.lng,
                                speed: p.speed, course: p.course, accuracy: p.accuracy,
                                altitude: p.altitude, onRoad: p.onRoad)
            tp.trip = trip
            ctx.insert(tp)
        }
        try? ctx.save()
        return true
    }

    private static func restoreMissingPoints(_ ctx: ModelContext, limit: Int) async {
        let none = set(noRemotePointsKey)
        let trips = ((try? ctx.fetch(FetchDescriptor<DriveTrip>(
            predicate: #Predicate { $0.remoteID != nil && !$0.isManualEntry },
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? [])
            .filter { $0.points.isEmpty && !none.contains($0.remoteID ?? "") }
        status.pendingPointDownloads = trips.count
        var done = 0
        for t in trips.prefix(limit) {
            if await restorePoints(for: t) { done += 1; status.pointsRestoredTrips += 1 }
            status.pendingPointDownloads = max(0, trips.count - done)
            await Task.yield()
        }
    }

    // MARK: Track points — upload

    static func uploadPoints(for trip: DriveTrip) async {
        guard let rid = trip.remoteID else { return }
        let pts = trip.orderedPoints
        guard pts.count >= 2 else { return }
        struct Body: Encodable { let points: [RemotePoint] }
        let body = Body(points: pts.enumerated().map { i, p in
            RemotePoint(seq: i, t: stamp(p.t), lat: p.lat, lng: p.lng, speed: p.speed,
                        course: p.course, accuracy: p.accuracy, altitude: p.altitude, onRoad: p.onRoad)
        })
        do {
            try await send("POST", "/api/trips/\(rid)/points", body)
            var pending = set(pendingPointUploadsKey); pending.remove(rid); store(pending, pendingPointUploadsKey)
        } catch {
            var pending = set(pendingPointUploadsKey); pending.insert(rid); store(pending, pendingPointUploadsKey)
        }
        status.pendingUploads = set(pendingPointUploadsKey).count
    }

    private static func flushPendingPointUploads(_ ctx: ModelContext) async {
        let pending = set(pendingPointUploadsKey)
        status.pendingUploads = pending.count
        guard !pending.isEmpty,
              let trips = try? ctx.fetch(FetchDescriptor<DriveTrip>(predicate: #Predicate { $0.remoteID != nil }))
        else { return }
        for t in trips where pending.contains(t.remoteID ?? "") { await uploadPoints(for: t) }
    }

    // MARK: Polyline decode (precision 5, matches `Polyline.encode`)

    private static func decodePolyline(_ s: String) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lng = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63; i += 1
                result |= (b & 0x1f) << shift; shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < bytes.count {
            guard let dLat = next(), let dLng = next() else { break }
            lat += dLat; lng += dLng
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
        }
        return coords
    }
}
