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
        var vehicleName: String?
        var vehicleMpg: Double?
        var scheduledArrival: Date?
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
            category: input.category,
            paidBy: input.paidBy,
            vehicleName: input.vehicleName,
            vehicleMpg: input.vehicleMpg,
            estimatedGallons: gallons,
            scheduledArrival: input.scheduledArrival,
            matchedFraction: match.matchedFraction,
            usedRouteMatching: match.usedRoute,
            matchedPolyline: matchedData
        )
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

    private static func movingSeconds(_ pts: [RecordedPoint]) -> Int {
        guard pts.count >= 2 else { return 0 }
        var s = 0.0
        for i in 1..<pts.count where pts[i].speed > 3 {
            s += pts[i].t.timeIntervalSince(pts[i - 1].t)
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
            duration: max(1, trip.duration / 60),
            notes: trip.notes,
            category: trip.categoryRaw,
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
