import Foundation
import SwiftData
import CoreLocation

/// Turns a finished recording into a persisted `DriveTrip`: runs map-matching, computes the
/// speed-aware fuel estimate, stores everything locally (source of truth), then best-effort
/// syncs a summary to the web backend. Network failures never lose local data.
@MainActor
enum TripStore {

    struct Input {
        var points: [RecordedPoint]
        var startAddress: String
        var endAddress: String
        var category: TripCategory
        var paidBy: PaidBy
        var notes: String?
        var name: String?
        var vehicleName: String?
        var vehicleMpg: Double?
        var scheduledDeparture: Date?
        var scheduledArrival: Date?
        var stops: [RouteStop] = []
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
        for trip in pending {
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
        }
        try? context.save()
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
            routeEncoded: Polyline.encode(displayCoords)
        )
        if let remote = try? await APIClient.createTrip(create) {
            await MainActor.run {
                trip.remoteID = remote.id
                trip.synced = true
            }
        }
    }
}
