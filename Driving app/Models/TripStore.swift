import Foundation
import SwiftData
import CoreLocation
import MapKit

/// Turns a finished recording into a persisted `DriveTrip`: runs map-matching, computes the
/// speed-aware fuel estimate, stores everything locally (source of truth), then best-effort
/// syncs a summary to the web backend. Network failures never lose local data.
@MainActor
enum TripStore {

    /// Trips currently being POSTed. Guards against the detached first-save upload racing a
    /// concurrent `syncPending` (dashboard `.task`, pull-to-refresh) and creating a duplicate
    /// remote row for the same drive.
    private static var uploading: Set<UUID> = []

    struct Input {
        var points: [RecordedPoint]
        var startAddress: String
        var endAddress: String
        var category: TripCategory
        /// A `PayerGroup.key`.
        var paidBy: String
        var notes: String?
        var name: String?
        var vehicleName: String?
        var vehicleMpg: Double?
        var scheduledDeparture: Date?
        var scheduledArrival: Date?
        var stops: [RouteStop] = []
        /// Journey linkage — set by `saveJourney` so a multi-stop drive's legs are separate but
        /// linked trips. Nil `journeyID` (the default) marks a standalone trip.
        var journeyID: UUID? = nil
        var legIndex: Int = 0
        var legTotal: Int = 1
    }

    @discardableResult
    static func save(_ input: Input, context: ModelContext) async -> DriveTrip? {
        let pts = input.points
        guard let first = pts.first, let last = pts.last, pts.count >= 2 else { return nil }

        // Measured distance + speeds from the raw track.
        var meters = 0.0
        for i in 1..<pts.count {
            let step = pts[i - 1].coordinate.distanceMeters(to: pts[i].coordinate)
            if step < 500 { meters += step }
        }
        let miles = meters / 1609.34
        let totalSeconds = Int(last.t.timeIntervalSince(first.t))
        let maxSpeed = pts.map(\.speed).max() ?? 0
        let avgSpeed = totalSeconds > 0 ? miles / (Double(totalSeconds) / 3600) : 0

        // Speed-aware fuel estimate.
        let segments = FuelModel.segments(from: pts)
        let mpg = input.vehicleMpg ?? 25
        let gallons = FuelModel.gallons(segments: segments, ratedMpg: mpg)

        // Map-matching (snap to roads, preserve deviations). Best-effort; raw fallback offline.
        let match = await RouteMatcher.match(points: pts)
        let matchedData = try? JSONEncoder().encode(match.coordinates.map { [$0.latitude, $0.longitude] })

        let trip = DriveTrip(
            date: first.t,
            endDate: last.t,
            startAddress: input.startAddress,
            endAddress: input.endAddress,
            startLat: first.lat, startLng: first.lng,
            endLat: last.lat, endLng: last.lng,
            distance: miles,
            duration: totalSeconds,
            movingSeconds: movingSeconds(pts),
            maxSpeed: maxSpeed,
            avgSpeed: avgSpeed,
            notes: input.notes,
            name: input.name,
            category: input.category,
            paidBy: input.paidBy,
            vehicleName: input.vehicleName,
            vehicleMpg: input.vehicleMpg,
            estimatedGallons: gallons,
            scheduledDeparture: input.scheduledDeparture,
            scheduledArrival: input.scheduledArrival,
            matchedFraction: match.matchedFraction,
            usedRouteMatching: match.usedRoute,
            matchedPolyline: matchedData
        )
        trip.stops = input.stops
        trip.journeyID = input.journeyID
        trip.legIndex = input.legIndex
        trip.legTotal = input.legTotal
        context.insert(trip)

        // Attach the full track for playback / analysis.
        for (i, p) in pts.enumerated() {
            let onRoad = i < match.onRoad.count ? match.onRoad[i] : false
            let tp = TrackPoint(seq: i, t: p.t, lat: p.lat, lng: p.lng,
                                speed: p.speed, course: p.course, accuracy: p.accuracy,
                                altitude: p.altitude, onRoad: onRoad)
            tp.trip = trip
            context.insert(tp)
        }

        try? context.save()

        // Best-effort remote sync (does not block; failure leaves the local trip intact/unsynced).
        Task.detached {
            await syncToBackend(trip: trip, displayCoords: match.coordinates)
        }
        return trip
    }

    /// Persist a finished multi-stop drive as several separate, **linked** trips — one per leg —
    /// sharing a `journeyID`. Each leg is a plain A→B trip: map-matched and synced independently
    /// (the backend just sees N trips); the journey link is a local grouping so the drives read as
    /// "separate trips that are linked" rather than one trip with pauses. Falls back to a single
    /// standalone trip when there's only one leg.
    @discardableResult
    static func saveJourney(_ legs: [Input], context: ModelContext) async -> [DriveTrip] {
        guard legs.count > 1 else {
            if let only = legs.first, let t = await save(only, context: context) { return [t] }
            return []
        }
        let journeyID = UUID()
        var saved: [DriveTrip] = []
        for (i, leg) in legs.enumerated() {
            var input = leg
            input.journeyID = journeyID
            input.legIndex = i
            input.legTotal = legs.count
            if let trip = await save(input, context: context) { saved.append(trip) }
        }
        return saved
    }

    /// After a leg is deleted from a journey, renumber the surviving siblings so their `legIndex` /
    /// `legTotal` stay correct (no "Leg 1 of 3" when only two remain). If only one leg is left it's
    /// demoted to a standalone trip — a journey of one is not a journey. No-op for a nil id.
    static func renumberJourney(_ journeyID: UUID?, context: ModelContext) {
        guard let jid = journeyID else { return }
        let desc = FetchDescriptor<DriveTrip>(predicate: #Predicate { $0.journeyID == jid },
                                              sortBy: [SortDescriptor(\.legIndex)])
        guard let legs = try? context.fetch(desc) else { return }
        if legs.count <= 1 {
            for t in legs { t.journeyID = nil; t.legIndex = 0; t.legTotal = 1 }
        } else {
            for (i, t) in legs.enumerated() { t.legIndex = i; t.legTotal = legs.count }
        }
        try? context.save()
    }

    /// Trim a recorded trip to the point range `keepStart...keepEnd`, discarding the track outside
    /// it — for when you forget to stop tracking (a stationary tail) or start it late. Deletes the
    /// removed `TrackPoint`s, recomputes every derived stat (distance, duration, speeds, moving time,
    /// speed-aware fuel, start/end coords + times), re-snaps the display polyline, re-labels any
    /// endpoint that moved, and best-effort pushes the new geometry to the web copy. Destructive.
    @discardableResult
    static func applyTrim(trip: DriveTrip, keepStart: Int, keepEnd: Int, context: ModelContext) async -> Bool {
        let ordered = trip.orderedPoints
        guard ordered.count >= 2 else { return false }
        let lo = max(0, min(keepStart, ordered.count - 2))
        let hi = max(lo + 1, min(keepEnd, ordered.count - 1))
        let kept = Array(ordered[lo...hi])
        guard kept.count >= 2 else { return false }
        let trimmedStart = lo > 0
        let trimmedEnd = hi < ordered.count - 1
        guard trimmedStart || trimmedEnd else { return false }  // nothing to do

        // Drop the removed points and reindex the survivors so `seq` stays contiguous.
        for (idx, tp) in ordered.enumerated() where idx < lo || idx > hi { context.delete(tp) }
        for (i, tp) in kept.enumerated() { tp.seq = i }

        // Recompute stats from the kept track (mirrors the save-time math).
        let recorded = kept.map {
            RecordedPoint(t: $0.t, coordinate: $0.coordinate, speed: $0.speed,
                          course: $0.course, accuracy: $0.accuracy, altitude: $0.altitude)
        }
        let first = recorded.first!, last = recorded.last!
        var meters = 0.0
        for i in 1..<recorded.count {
            let step = recorded[i - 1].coordinate.distanceMeters(to: recorded[i].coordinate)
            if step < 500 { meters += step }
        }
        let miles = meters / 1609.34
        let secs = Int(last.t.timeIntervalSince(first.t))
        trip.date = first.t
        trip.endDate = last.t
        trip.distance = miles
        trip.duration = secs
        trip.movingSeconds = movingSeconds(recorded)
        trip.maxSpeed = recorded.map(\.speed).max() ?? 0
        trip.avgSpeed = secs > 0 ? miles / (Double(secs) / 3600) : 0
        trip.startLat = first.lat; trip.startLng = first.lng
        trip.endLat = last.lat; trip.endLng = last.lng
        let mpg = trip.vehicleMpg ?? 25
        trip.estimatedGallons = FuelModel.gallons(segments: FuelModel.segments(from: recorded), ratedMpg: mpg)

        // Re-snap the display polyline to the shorter track — but ONLY apply a successful match.
        // A failed re-match (offline / directions error) returns a raw fallback; writing it would
        // permanently wipe this trip's existing road-snapping, per the rule that a failed
        // network-only step must never degrade local data. On failure, drop the now-stale snapped
        // polyline (it still covered the trimmed-away tail) so the map shows the trimmed raw track,
        // and keep the existing matchedFraction / usedRouteMatching / per-point onRoad flags.
        let match = await RouteMatcher.match(points: recorded)
        if match.usedRoute {
            trip.matchedFraction = match.matchedFraction
            trip.usedRouteMatching = true
            trip.matchedPolyline = try? JSONEncoder().encode(match.coordinates.map { [$0.latitude, $0.longitude] })
            for (i, tp) in kept.enumerated() {
                tp.onRoad = i < match.onRoad.count ? match.onRoad[i] : false
            }
        } else {
            trip.matchedPolyline = nil
        }

        // Re-label endpoints that moved (best-effort geocode).
        if trimmedStart, let name = await reverseGeocode(first.coordinate) { trip.startAddress = name }
        if trimmedEnd, let name = await reverseGeocode(last.coordinate) { trip.endAddress = name }

        try? context.save()

        // Best-effort: push the rewritten geometry/stats — including the new endpoints & addresses —
        // to the web copy so its map markers and labels stay consistent with the trimmed route.
        if let remoteID = trip.remoteID {
            let f = ISO8601DateFormatter()
            try? await APIClient.patchTripTrim(
                id: remoteID,
                date: f.string(from: trip.date),
                distance: trip.distance,
                duration: max(1, (trip.duration + 30) / 60),
                startAddress: trip.startAddress, endAddress: trip.endAddress,
                startLat: trip.startLat, startLng: trip.startLng,
                endLat: trip.endLat, endLng: trip.endLng,
                routeEncoded: Polyline.encode(trip.displayCoordinates))
        }
        return true
    }

    private static func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let req = MKReverseGeocodingRequest(location: loc) else { return nil }
        if let items = try? await req.mapItems, let name = items.first?.name, !name.isEmpty { return name }
        return nil
    }

    /// Retroactively update every past trip in a car when its name or MPG changes: re-point the
    /// trips to the (possibly new) name and recompute their speed-aware fuel estimate with the new
    /// MPG. This keeps the gas-used and paid-by-cost numbers consistent across the whole history.
    static func updateTripsForVehicle(oldName: String, newName: String, newMpg: Double?, context: ModelContext) {
        let descriptor = FetchDescriptor<DriveTrip>(predicate: #Predicate { $0.vehicleName == oldName })
        guard let trips = try? context.fetch(descriptor), !trips.isEmpty else { return }
        for trip in trips {
            trip.vehicleName = newName
            guard let mpg = newMpg, mpg > 0 else { continue }
            trip.vehicleMpg = mpg
            let recorded = trip.orderedPoints.map {
                RecordedPoint(t: $0.t, coordinate: $0.coordinate, speed: $0.speed,
                              course: $0.course, accuracy: $0.accuracy, altitude: $0.altitude)
            }
            if recorded.count >= 2 {
                trip.estimatedGallons = FuelModel.gallons(segments: FuelModel.segments(from: recorded), ratedMpg: mpg)
            } else {
                trip.estimatedGallons = trip.distance / mpg
            }
        }
        try? context.save()
    }

    /// Push any locally-recorded trips that haven't reached the backend yet. The phone is the
    /// source of truth, so a "pull to refresh" flushes outstanding uploads rather than fetching.
    /// Safe to call repeatedly — only unsynced trips are sent. Returns the number newly synced.
    @MainActor
    @discardableResult
    /// One-time backfill of `paidBy` onto trips that were synced before the server had the column
    /// (their remote rows all defaulted to SELF). PATCHes each already-synced trip's real payer by
    /// its remote id — non-destructive (never creates or deletes) and idempotent. Only marks itself
    /// done once every PATCH has succeeded, so it safely retries after a network failure.
    static func backfillPaidBy(context: ModelContext) async {
        let doneKey = "didBackfillTripPaidBy.v1"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        guard let trips = try? context.fetch(FetchDescriptor<DriveTrip>()) else { return }
        var allSucceeded = true
        for trip in trips where trip.synced {
            guard let remoteID = trip.remoteID else { continue }
            do { try await APIClient.patchTripPaidBy(id: remoteID, paidBy: trip.paidByRaw) }
            catch { allSucceeded = false }
        }
        if allSucceeded { UserDefaults.standard.set(true, forKey: doneKey) }
    }

    /// Push a trip's edited stops to its already-synced remote row (best-effort). No-op if the trip
    /// hasn't synced yet — its stops go up with the initial create instead.
    static func syncStops(for trip: DriveTrip) async {
        guard let remoteID = trip.remoteID else { return }
        try? await APIClient.patchTripStops(id: remoteID, stops: trip.stops)
    }

    static func syncPending(context: ModelContext) async -> Int {
        let descriptor = FetchDescriptor<DriveTrip>(predicate: #Predicate { !$0.synced })
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return 0 }
        var synced = 0
        for trip in pending where !uploading.contains(trip.id) {
            uploading.insert(trip.id)
            defer { uploading.remove(trip.id) }
            // Re-check freshness after taking the slot: the detached first-save `syncToBackend` for
            // this same trip can complete (flipping `synced` and freeing the slot) during an earlier
            // iteration's `await`, so without this a backlog would upload it a second time.
            if trip.synced { continue }
            let f = ISO8601DateFormatter()
            let create = APITripCreate(
                date: f.string(from: trip.date),
                startAddress: trip.startAddress,
                endAddress: trip.endAddress,
                startLat: trip.startLat, startLng: trip.startLng,
                endLat: trip.endLat, endLng: trip.endLng,
                distance: trip.distance,
                duration: max(1, (trip.duration + 30) / 60),
                notes: trip.notes,
                category: trip.categoryRaw,
                paidBy: trip.paidByRaw,
                stops: trip.stops,
                routeEncoded: Polyline.encode(trip.displayCoordinates)
            )
            if let remote = try? await APIClient.createTrip(create) {
                trip.remoteID = remote.id
                trip.synced = true
                synced += 1
            }
            try? context.save()  // persist each result immediately so a crash can't re-upload it
        }
        return synced
    }

    private static func movingSeconds(_ pts: [RecordedPoint]) -> Int {
        guard pts.count >= 2 else { return 0 }
        var s = 0.0
        for i in 1..<pts.count {
            // Use the interval's representative speed (average of its endpoints) so a pure idle
            // interval isn't counted, while genuine accel/decel intervals are.
            let avg = (pts[i].speed + pts[i - 1].speed) / 2
            if avg > 3 {
                s += pts[i].t.timeIntervalSince(pts[i - 1].t)
            }
        }
        return Int(s)
    }

    private static func syncToBackend(trip: DriveTrip, displayCoords: [CLLocationCoordinate2D]) async {
        // Skip if this trip is already being uploaded (or has been) by another path.
        guard !trip.synced, !uploading.contains(trip.id) else { return }
        uploading.insert(trip.id)
        defer { uploading.remove(trip.id) }
        let f = ISO8601DateFormatter()
        let create = APITripCreate(
            date: f.string(from: trip.date),
            startAddress: trip.startAddress,
            endAddress: trip.endAddress,
            startLat: trip.startLat, startLng: trip.startLng,
            endLat: trip.endLat, endLng: trip.endLng,
            distance: trip.distance,
            // Round to the nearest minute (not truncate) so a 90s trip reports 2 min, not 1.
            duration: max(1, (trip.duration + 30) / 60),
            notes: trip.notes,
            category: trip.categoryRaw,
            paidBy: trip.paidByRaw,
            // Include the multi-stop stops on the primary sync path too — this trip is marked
            // `synced` right after, so `syncPending` (which does send stops) never revisits it.
            stops: trip.stops,
            routeEncoded: Polyline.encode(displayCoords)
        )
        if let remote = try? await APIClient.createTrip(create) {
            trip.remoteID = remote.id
            trip.synced = true
            // Persist the synced flag now so an app kill before SwiftData's autosave can't
            // re-upload this trip on next launch (a second duplicate remote row).
            try? trip.modelContext?.save()
        }
    }
}
