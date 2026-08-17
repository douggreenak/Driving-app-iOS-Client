import Foundation
import SwiftData
import CoreLocation

enum TripCategory: String, Codable, CaseIterable {
    case commute = "COMMUTE"
    case errand = "ERRAND"
    case school = "SCHOOL"
    case work = "WORK"
    case roadTrip = "ROAD_TRIP"
    case leisure = "LEISURE"
    case other = "OTHER"

    var label: String {
        switch self {
        case .commute: "Commute"
        case .errand: "Errand"
        case .school: "School"
        case .work: "Work"
        case .roadTrip: "Road Trip"
        case .leisure: "Leisure"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .commute: "house.fill"
        case .errand: "cart.fill"
        case .school: "graduationcap.fill"
        case .work: "briefcase.fill"
        case .roadTrip: "road.lanes"
        case .leisure: "sparkles"
        case .other: "mappin"
        }
    }
}

enum FuelType: String, Codable, CaseIterable {
    case regular = "REGULAR"
    case midgrade = "MIDGRADE"
    case premium = "PREMIUM"
    case diesel = "DIESEL"

    var label: String {
        switch self {
        case .regular: "Regular (87)"
        case .midgrade: "Midgrade (89)"
        case .premium: "Premium (91+)"
        case .diesel: "Diesel"
        }
    }

    /// Just the grade name, no octane parenthetical — used where space is tight (the segmented
    /// picker) so all four options stay equal width without truncating.
    var shortLabel: String {
        switch self {
        case .regular: "Regular"
        case .midgrade: "Midgrade"
        case .premium: "Premium"
        case .diesel: "Diesel"
        }
    }
}

/// How a scheduled drive repeats.
enum RepeatRule: String, Codable, CaseIterable {
    case none = "NONE"
    case daily = "DAILY"
    case weekdays = "WEEKDAYS"
    case weekly = "WEEKLY"

    var label: String {
        switch self {
        case .none: "Does not repeat"
        case .daily: "Every day"
        case .weekdays: "Weekdays (Mon–Fri)"
        case .weekly: "Every week"
        }
    }

    var shortLabel: String {
        switch self {
        case .none: "Once"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        }
    }
}

/// An intermediate stop on a route (between the start and the final destination). Stored as a
/// Codable value on both scheduled drives and recorded trips so any route can be multi-stop.
struct RouteStop: Codable, Hashable, Identifiable {
    var id = UUID()
    var address: String
    var lat: Double
    var lng: Double
    /// How many minutes the driver plans to spend at this stop before continuing.
    /// Factored into the scheduled drive's estimated arrival time. Defaults to 0 (pass-through).
    var dwellMinutes: Int = 0
    /// The expected driving time (seconds) for the leg that ends at this stop.
    /// e.g. for stop 1, this is the driving time from start → stop 1.
    var legDriveSeconds: Int = 0

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }

    // `id` is local-only (not sent to or required from the server) — encode/decode address,
    // coordinate, dwellMinutes, and legDriveSeconds so a stop round-trips cleanly through the JSON API and SwiftData.
    // `dwellMinutes` and `legDriveSeconds` decode with a fallback of 0 so existing records load without error.
    enum CodingKeys: String, CodingKey { case address, lat, lng, dwellMinutes, legDriveSeconds }

    init(id: UUID = UUID(), address: String, lat: Double, lng: Double, dwellMinutes: Int = 0, legDriveSeconds: Int = 0) {
        self.id = id
        self.address = address
        self.lat = lat
        self.lng = lng
        self.dwellMinutes = dwellMinutes
        self.legDriveSeconds = legDriveSeconds
    }
    init(id: UUID = UUID(), address: String, coordinate: CLLocationCoordinate2D, dwellMinutes: Int = 0, legDriveSeconds: Int = 0) {
        self.init(id: id, address: address, lat: coordinate.latitude, lng: coordinate.longitude, dwellMinutes: dwellMinutes, legDriveSeconds: legDriveSeconds)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.address = try c.decode(String.self, forKey: .address)
        self.lat = try c.decode(Double.self, forKey: .lat)
        self.lng = try c.decode(Double.self, forKey: .lng)
        self.dwellMinutes = (try? c.decode(Int.self, forKey: .dwellMinutes)) ?? 0
        self.legDriveSeconds = (try? c.decode(Int.self, forKey: .legDriveSeconds)) ?? 0
    }
}

// MARK: - Recorded drive (local source of truth)

@Model
final class DriveTrip {
    var id: UUID = UUID()
    /// Departure / start time.
    var date: Date
    /// Actual arrival time.
    var endDate: Date
    var startAddress: String
    var endAddress: String
    var startLat: Double
    var startLng: Double
    var endLat: Double
    var endLng: Double
    /// Miles, measured from the recorded track.
    var distance: Double
    /// Total elapsed seconds (including stops).
    var duration: Int
    /// Seconds the car was actually moving.
    var movingSeconds: Int
    var maxSpeed: Double
    var avgSpeed: Double
    var notes: String?
    /// Title carried over from the schedule this drive was run from (e.g. "Morning Commute").
    var name: String?
    var categoryRaw: String
    var isFavorite: Bool
    /// Who covers this drive's fuel cost — the app's core concept. Stores a `PayerGroup.key` (see
    /// Models/PayerGroup.swift); resolve to a display name/icon/color via `PayerGroup.resolve(key:in:)`.
    var paidByRaw: String = PayerGroup.selfKey

    /// Intermediate stops on this trip (multi-stop), start → stops → end. Empty for a simple A→B.
    var stops: [RouteStop] = []

    /// Legs of one multi-stop journey share a `journeyID` (nil for a standalone trip). `legIndex`
    /// orders them (0-based) and `legTotal` is the journey's leg count. This lets a multi-stop
    /// drive be recorded as separate, *linked* trips instead of one trip with pauses.
    var journeyID: UUID?
    var legIndex: Int = 0
    var legTotal: Int = 1

    var vehicleName: String?
    var vehicleMpg: Double?
    /// Speed-aware fuel estimate (gallons).
    var estimatedGallons: Double

    /// Scheduled departure & arrival this drive was measured against (if launched from a schedule).
    var scheduledDeparture: Date?
    var scheduledArrival: Date?

    /// Map-matching outputs.
    var matchedFraction: Double
    var usedRouteMatching: Bool
    /// Snapped/deviation display polyline, encoded as JSON `[[lat,lng], ...]`.
    var matchedPolyline: Data?

    /// Remote sync bookkeeping.
    var remoteID: String?
    var synced: Bool

    /// True for a drive logged after the fact (e.g. "forgot to hit record") instead of GPS-tracked
    /// live. Its distance/route come from a MapKit lookup between the entered start/end and its
    /// duration from the entered departure/arrival — never from a real recorded track. Shown as a
    /// clear "not a recorded drive" notice everywhere this trip appears.
    var isManualEntry: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \TrackPoint.trip)
    var points: [TrackPoint]
    @Relationship(deleteRule: .cascade, inverse: \GasEntry.trip)
    var gasEntries: [GasEntry]

    var category: TripCategory {
        get { TripCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// True when this trip is one leg of a linked multi-stop journey.
    var isJourneyLeg: Bool { journeyID != nil && legTotal > 1 }

    init(
        date: Date,
        endDate: Date,
        startAddress: String,
        endAddress: String,
        startLat: Double,
        startLng: Double,
        endLat: Double,
        endLng: Double,
        distance: Double,
        duration: Int,
        movingSeconds: Int = 0,
        maxSpeed: Double = 0,
        avgSpeed: Double = 0,
        notes: String? = nil,
        name: String? = nil,
        category: TripCategory = .other,
        isFavorite: Bool = false,
        paidBy: String = PayerGroup.selfKey,
        vehicleName: String? = nil,
        vehicleMpg: Double? = nil,
        estimatedGallons: Double = 0,
        scheduledDeparture: Date? = nil,
        scheduledArrival: Date? = nil,
        matchedFraction: Double = 0,
        usedRouteMatching: Bool = false,
        matchedPolyline: Data? = nil,
        isManualEntry: Bool = false
    ) {
        self.date = date
        self.endDate = endDate
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.startLat = startLat
        self.startLng = startLng
        self.endLat = endLat
        self.endLng = endLng
        self.distance = distance
        self.duration = duration
        self.movingSeconds = movingSeconds
        self.maxSpeed = maxSpeed
        self.avgSpeed = avgSpeed
        self.notes = notes
        self.name = name
        self.categoryRaw = category.rawValue
        self.isFavorite = isFavorite
        self.paidByRaw = paidBy
        self.vehicleName = vehicleName
        self.vehicleMpg = vehicleMpg
        self.estimatedGallons = estimatedGallons
        self.scheduledDeparture = scheduledDeparture
        self.scheduledArrival = scheduledArrival
        self.matchedFraction = matchedFraction
        self.usedRouteMatching = usedRouteMatching
        self.matchedPolyline = matchedPolyline
        self.isManualEntry = isManualEntry
        self.remoteID = nil
        self.synced = false
        self.points = []
        self.gasEntries = []
    }

    var startCoordinate: CLLocationCoordinate2D {
        .init(latitude: startLat, longitude: startLng)
    }
    var endCoordinate: CLLocationCoordinate2D {
        .init(latitude: endLat, longitude: endLng)
    }

    /// Track points in chronological order.
    var orderedPoints: [TrackPoint] {
        points.sorted { $0.seq < $1.seq }
    }

    /// Display polyline (snapped + deviations), decoded from `matchedPolyline`,
    /// or the raw track if matching wasn't stored.
    var displayCoordinates: [CLLocationCoordinate2D] {
        if let data = matchedPolyline,
           let arr = try? JSONDecoder().decode([[Double]].self, from: data) {
            return arr.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        }
        return orderedPoints.map { $0.coordinate }
    }

    /// How late the actual departure was vs. the scheduled departure (positive = late). Nil if
    /// the drive wasn't run from a schedule.
    var departureDelaySeconds: Int? {
        guard let scheduledDeparture else { return nil }
        return Int(date.timeIntervalSince(scheduledDeparture))
    }

    /// Delay vs. the scheduled arrival in seconds (positive = late). Nil if not scheduled.
    var delaySeconds: Int? {
        guard let scheduledArrival else { return nil }
        return Int(endDate.timeIntervalSince(scheduledArrival))
    }
}

@Model
final class TrackPoint {
    var seq: Int
    var t: Date
    var lat: Double
    var lng: Double
    /// mph
    var speed: Double
    /// degrees, -1 if invalid
    var course: Double
    /// meters
    var accuracy: Double
    /// feet above sea level
    var altitude: Double = 0
    /// Was this fix matched onto a known road?
    var onRoad: Bool
    var trip: DriveTrip?

    init(seq: Int, t: Date, lat: Double, lng: Double, speed: Double, course: Double, accuracy: Double, altitude: Double = 0, onRoad: Bool = false) {
        self.seq = seq
        self.t = t
        self.lat = lat
        self.lng = lng
        self.speed = speed
        self.course = course
        self.accuracy = accuracy
        self.altitude = altitude
        self.onRoad = onRoad
    }

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: lat, longitude: lng)
    }
}

// MARK: - Scheduled drive

@Model
final class ScheduledDrive {
    var id: UUID = UUID()
    var title: String
    var startAddress: String
    var endAddress: String
    var startLat: Double
    var startLng: Double
    var endLat: Double
    var endLng: Double
    /// Scheduled departure (its date+time is the next single occurrence's anchor).
    var departure: Date
    /// Predicted travel seconds from the routing engine.
    var estimatedTravelTime: Int
    /// Auto-filled (departure + travel), user-adjustable.
    var scheduledArrival: Date
    var repeatRuleRaw: String
    var categoryRaw: String
    /// Default payer for drives started from this schedule. Stores a `PayerGroup.key`.
    var paidByRaw: String = PayerGroup.selfKey
    /// Intermediate stops on this scheduled route (multi-stop), start → stops → end.
    var stops: [RouteStop] = []
    var vehicleName: String?
    var notes: String?
    var isEnabled: Bool
    var lastStartedAt: Date?
    /// When the drive was last completed (tracking stopped). Used to drop a finished occurrence
    /// off the departures board.
    var lastCompletedAt: Date?
    /// Individual occurrences the user deleted via "just this once" — the repeat keeps going, but
    /// these specific departures are skipped. Matched by time when expanding occurrences.
    var skippedOccurrences: [Date] = []
    /// Individual occurrences the user canceled via "just this once". Unlike a skipped occurrence
    /// (which is removed entirely), a canceled one stays visible on the departures board with a
    /// CANCELED status — the repeat keeps going and every other occurrence is unaffected. Matched
    /// by time, like `skippedOccurrences`.
    var canceledOccurrences: [Date] = []
    var createdAt: Date = Date()
    /// Remote sync bookkeeping (best-effort mirror to the web DB).
    var remoteID: String?
    var synced: Bool = false

    init(
        title: String,
        startAddress: String,
        endAddress: String,
        startLat: Double,
        startLng: Double,
        endLat: Double,
        endLng: Double,
        departure: Date,
        estimatedTravelTime: Int,
        scheduledArrival: Date,
        repeatRule: RepeatRule = .none,
        category: TripCategory = .commute,
        paidBy: String = PayerGroup.selfKey,
        vehicleName: String? = nil,
        notes: String? = nil,
        isEnabled: Bool = true
    ) {
        self.title = title
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.startLat = startLat
        self.startLng = startLng
        self.endLat = endLat
        self.endLng = endLng
        self.departure = departure
        self.estimatedTravelTime = estimatedTravelTime
        self.scheduledArrival = scheduledArrival
        self.repeatRuleRaw = repeatRule.rawValue
        self.categoryRaw = category.rawValue
        self.paidByRaw = paidBy
        self.vehicleName = vehicleName
        self.notes = notes
        self.isEnabled = isEnabled
    }

    var category: TripCategory {
        get { TripCategory(rawValue: categoryRaw) ?? .commute }
        set { categoryRaw = newValue.rawValue }
    }

    var repeatRule: RepeatRule {
        get { RepeatRule(rawValue: repeatRuleRaw) ?? .none }
        set { repeatRuleRaw = newValue.rawValue }
    }

    var startCoordinate: CLLocationCoordinate2D { .init(latitude: startLat, longitude: startLng) }
    var endCoordinate: CLLocationCoordinate2D { .init(latitude: endLat, longitude: endLng) }

    /// Ordered route waypoints: start → intermediate stops → destination.
    var routeCoordinates: [CLLocationCoordinate2D] {
        [startCoordinate] + stops.map(\.coordinate) + [endCoordinate]
    }

    /// Next concrete departure at or after `reference`, honoring the repeat rule.
    func nextDeparture(after reference: Date = .now) -> Date {
        let cal = Calendar.current
        if repeatRule == .none {
            return departure
        }
        // Compose a candidate today at the scheduled time-of-day, then advance per rule.
        let time = cal.dateComponents([.hour, .minute], from: departure)
        // The series can't start before its own first departure day — otherwise a drive whose first
        // departure is in the future would report phantom occurrences today (and read as LATE).
        let firstDay = cal.startOfDay(for: departure)
        var candidate = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: reference) ?? departure
        for _ in 0..<400 {
            if candidate >= reference && candidate >= firstDay
                && matchesRule(candidate, calendar: cal)
                && !isSkipped(candidate) && !isOccurrenceCanceled(candidate) {
                return candidate
            }
            candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    /// True if this exact occurrence was deleted "just this once". Matched with a small tolerance
    /// since occurrence times are recomputed (not stored byte-for-byte).
    func isSkipped(_ date: Date) -> Bool {
        skippedOccurrences.contains { abs($0.timeIntervalSince(date)) < 60 }
    }

    /// True if this exact occurrence was canceled "just this once". Matched with the same tolerance
    /// as `isSkipped` since occurrence times are recomputed, not stored byte-for-byte.
    func isOccurrenceCanceled(_ date: Date) -> Bool {
        canceledOccurrences.contains { abs($0.timeIntervalSince(date)) < 60 }
    }

    /// Cancel or restore a single occurrence. Canceling affects only this one departure — the
    /// repeat continues and every other occurrence stays scheduled.
    ///
    /// The array is rebuilt and reassigned as a whole (rather than mutated in place) so SwiftData
    /// reliably registers the change and every `@Query` observing this drive — the dashboard's
    /// "Up Next" hero in particular — re-evaluates immediately. Without the reassignment a canceled
    /// occurrence could linger in Up Next until an unrelated refresh.
    func setOccurrenceCanceled(_ date: Date, _ canceled: Bool) {
        var updated = canceledOccurrences
        if canceled {
            if !isOccurrenceCanceled(date) { updated.append(date) }
        } else {
            updated.removeAll { abs($0.timeIntervalSince(date)) < 60 }
        }
        canceledOccurrences = updated
    }

    private func matchesRule(_ date: Date, calendar cal: Calendar) -> Bool {
        switch repeatRule {
        case .none: return true
        case .daily: return true
        case .weekdays:
            let wd = cal.component(.weekday, from: date)  // 1=Sun ... 7=Sat
            return wd >= 2 && wd <= 6
        case .weekly:
            return cal.component(.weekday, from: date) == cal.component(.weekday, from: departure)
        }
    }

    /// Next arrival, derived from the next departure plus the predicted travel time.
    func nextArrival(after reference: Date = .now) -> Date {
        nextDeparture(after: reference).addingTimeInterval(TimeInterval(estimatedTravelTime))
    }

    /// Most recent occurrence departure at or before `reference`, or nil if the drive's first
    /// occurrence is still in the future.
    func previousDeparture(before reference: Date = .now) -> Date? {
        let cal = Calendar.current
        if repeatRule == .none {
            return departure <= reference ? departure : nil
        }
        let time = cal.dateComponents([.hour, .minute], from: departure)
        var candidate = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: reference) ?? departure
        let firstDay = cal.startOfDay(for: departure)
        for _ in 0..<400 {
            if candidate < firstDay { return nil }
            // Ignore occurrences deleted or canceled "just this once" so that departure can't
            // resurface as the status reference and read LATE / show in Up Next.
            if candidate <= reference && matchesRule(candidate, calendar: cal)
                && !isSkipped(candidate) && !isOccurrenceCanceled(candidate) {
                return candidate
            }
            candidate = cal.date(byAdding: .day, value: -1, to: candidate) ?? candidate
        }
        return nil
    }

    /// The occurrence the on-time status is judged against: whichever scheduled departure — the
    /// most recent past one or the next upcoming one — is nearer to `now`. This way a drive whose
    /// scheduled window has already passed (and wasn't started) is evaluated against *that*
    /// occurrence and reads as late, instead of silently rolling to the next one.
    func statusReferenceDeparture(now: Date = .now) -> Date {
        let next = nextDeparture(after: now)
        guard let prev = previousDeparture(before: now), prev != next else { return next }
        return abs(now.timeIntervalSince(prev)) <= abs(next.timeIntervalSince(now)) ? prev : next
    }

    /// The arrival we currently *expect* for the reference occurrence: leave on time if that's
    /// still possible, otherwise leave now, then add the predicted travel time.
    func estimatedArrival(now: Date = .now) -> Date {
        max(statusReferenceDeparture(now: now), now).addingTimeInterval(TimeInterval(estimatedTravelTime))
    }

    /// The arrival the drive is *scheduled* to make for the reference occurrence (the user's
    /// target arrival budget `scheduledArrival - departure` carried onto that occurrence's date).
    func targetArrival(now: Date = .now) -> Date {
        let budget = scheduledArrival.timeIntervalSince(departure)
        return statusReferenceDeparture(now: now).addingTimeInterval(budget)
    }

    /// On-time delay: estimated arrival minus scheduled arrival for the reference occurrence.
    /// Positive = projected (or already) late, negative = projected early.
    func arrivalDelaySeconds(now: Date = .now) -> Int {
        Int(estimatedArrival(now: now).timeIntervalSince(targetArrival(now: now)))
    }

    /// The arrival-budget the user set between departure and scheduled arrival.
    var arrivalBudget: TimeInterval { scheduledArrival.timeIntervalSince(departure) }

    /// Was the given occurrence already driven (a recorded start or completion inside its window)?
    private func wasDriven(_ dep: Date) -> Bool {
        let lo = dep.addingTimeInterval(-1800)
        let hi = dep.addingTimeInterval(arrivalBudget + 6 * 3600)
        if let s = lastStartedAt, s >= lo, s <= hi { return true }
        if let c = lastCompletedAt, c >= lo, c <= hi { return true }
        return false
    }

    /// The occurrence nearest to `now` **including canceled ones** — the slot the user is currently
    /// "in". Unlike `statusReferenceDeparture` (which skips canceled occurrences), this is used to
    /// detect when the imminent occurrence has been canceled, so the drive isn't rolled forward and
    /// re-promoted into Up Next behind the user's back.
    private func rawNearestOccurrence(now: Date) -> Date? {
        let cal = Calendar.current
        if repeatRule == .none { return departure }
        let time = cal.dateComponents([.hour, .minute], from: departure)
        let firstDay = cal.startOfDay(for: departure)
        let anchor = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now) ?? departure
        // Nearest raw future occurrence (>= now), ignoring cancellation.
        var rawNext: Date?
        var c = anchor
        for _ in 0..<400 {
            if c >= now, c >= firstDay, matchesRule(c, calendar: cal), !isSkipped(c) { rawNext = c; break }
            c = cal.date(byAdding: .day, value: 1, to: c) ?? c
        }
        // Nearest raw past occurrence (<= now), ignoring cancellation.
        var rawPrev: Date?
        c = anchor
        for _ in 0..<400 {
            if c < firstDay { break }
            if c <= now, matchesRule(c, calendar: cal), !isSkipped(c) { rawPrev = c; break }
            c = cal.date(byAdding: .day, value: -1, to: c) ?? c
        }
        switch (rawPrev, rawNext) {
        case let (p?, n?): return abs(now.timeIntervalSince(p)) <= abs(n.timeIntervalSince(now)) ? p : n
        case let (p?, nil): return p
        case let (nil, n?): return n
        default: return nil
        }
    }

    /// The departure this drive is currently "at" for the dashboard's Up Next surface. A drive
    /// that's overdue to leave but hasn't been started still counts (so a *late* drive isn't
    /// skipped in favor of a later on-time one) — within a 6h grace window. Returns nil when
    /// nothing is pending soon (already driven, canceled, or a one-time drive long past).
    func upNextDeparture(now: Date = .now) -> Date? {
        // If the occurrence the user is currently at/near is canceled AND still within its own
        // window, this drive has nothing pending right now — do NOT roll forward and re-promote the
        // just-canceled drive (that read as "the canceled trip still shows in Up Next"). Only the
        // canceled occurrence's own window is suppressed: once it's clearly past, the next
        // occurrence surfaces normally instead of the drive staying hidden for days. The canceled
        // occurrence stays visible on the departures board with a CANCELED status throughout.
        if let raw = rawNearestOccurrence(now: now), isOccurrenceCanceled(raw),
           now < raw.addingTimeInterval(arrivalBudget + 6 * 3600) { return nil }
        let ref = statusReferenceDeparture(now: now)
        if !wasDriven(ref), !isOccurrenceCanceled(ref), ref >= now.addingTimeInterval(-6 * 3600) { return ref }
        let next = nextDeparture(after: now)
        return (next > now && !wasDriven(next) && !isOccurrenceCanceled(next)) ? next : nil
    }

    /// True when the scheduled departure (start) time has passed for the reference occurrence —
    /// i.e. the start is running late, independent of the arrival.
    func departureIsLate(now: Date = .now) -> Bool {
        now.timeIntervalSince(statusReferenceDeparture(now: now)) > 90
    }

    /// True when the projected arrival (end) is later than its scheduled arrival.
    func arrivalIsLate(now: Date = .now) -> Bool {
        arrivalDelaySeconds(now: now) > 90
    }

    /// Concrete departure datetimes for this drive within `range`, honoring the repeat rule —
    /// used to build the departures board (one entry per occurrence).
    func occurrences(in range: ClosedRange<Date>) -> [Date] {
        let cal = Calendar.current
        if repeatRule == .none {
            return (range.contains(departure) && !isSkipped(departure)) ? [departure] : []
        }
        let time = cal.dateComponents([.hour, .minute], from: departure)
        let firstDay = cal.startOfDay(for: departure)
        var day = cal.startOfDay(for: range.lowerBound)
        var result: [Date] = []
        // Cap high enough (~11 years of days) that the infinite-scroll horizon never truncates a
        // repeating series; the real bound is `day > range.upperBound` below.
        for _ in 0..<4200 {
            if day > range.upperBound { break }
            if let occ = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day),
               occ >= firstDay, range.contains(occ), matchesRule(occ, calendar: cal), !isSkipped(occ) {
                result.append(occ)
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return result
    }
}

// MARK: - Gas, Vehicle, Settings

@Model
final class GasEntry {
    var date: Date
    var gallons: Double
    var pricePerGallon: Double
    var totalCost: Double
    var paidByRaw: String
    var fuelTypeRaw: String
    var stationName: String?
    var odometer: Double?
    var trip: DriveTrip?

    var fuelType: FuelType {
        get { FuelType(rawValue: fuelTypeRaw) ?? .regular }
        set { fuelTypeRaw = newValue.rawValue }
    }

    init(
        date: Date = .now,
        gallons: Double,
        pricePerGallon: Double,
        paidBy: String,
        fuelType: FuelType = .regular,
        stationName: String? = nil,
        odometer: Double? = nil,
        trip: DriveTrip? = nil
    ) {
        self.date = date
        self.gallons = gallons
        self.pricePerGallon = pricePerGallon
        self.totalCost = gallons * pricePerGallon
        self.paidByRaw = paidBy
        self.fuelTypeRaw = fuelType.rawValue
        self.stationName = stationName
        self.odometer = odometer
        self.trip = trip
    }
}

@Model
final class Vehicle {
    var name: String
    var make: String?
    var model: String?
    var year: Int?
    var tankSize: Double?
    var avgMpg: Double?
    /// Date of this car's most recent fill-up. The paid-by gas cost only counts trips since then.
    var lastFilledUp: Date?

    init(name: String, make: String? = nil, model: String? = nil, year: Int? = nil, tankSize: Double? = nil, avgMpg: Double? = nil) {
        self.name = name
        self.make = make
        self.model = model
        self.year = year
        self.tankSize = tankSize
        self.avgMpg = avgMpg
    }
}

@Model
final class UserSettings {
    var monthlyBudget: Double
    var distanceUnit: String
    /// Used to estimate per-drive fuel cost for the paid-by breakdowns.
    var fuelPricePerGallon: Double = 3.75
    /// Default payer for ad-hoc (non-scheduled) drives — the trip-summary picker and "Go to" trips
    /// start here. Scheduled drives carry their own payer instead of using this. Stores a
    /// `PayerGroup.key`.
    var defaultPaidByRaw: String = PayerGroup.selfKey

    init(monthlyBudget: Double = 0, distanceUnit: String = "miles") {
        self.monthlyBudget = monthlyBudget
        self.distanceUnit = distanceUnit
    }
}

/// A bookmarked location (Home, Shop, School, …) for quick address entry.
@Model
final class SavedPlace {
    var id: UUID = UUID()
    var label: String
    var address: String
    var lat: Double
    var lng: Double
    var icon: String
    var sortOrder: Int
    var createdAt: Date = Date()

    init(label: String, address: String, lat: Double, lng: Double, icon: String = "mappin.circle.fill", sortOrder: Int = 0) {
        self.label = label
        self.address = address
        self.lat = lat
        self.lng = lng
        self.icon = icon
        self.sortOrder = sortOrder
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }

    /// Common bookmark presets the user can pick an icon/label from.
    static let presets: [(label: String, icon: String)] = [
        ("Home", "house.fill"),
        ("Work", "briefcase.fill"),
        ("Shop", "cart.fill"),
        ("School", "graduationcap.fill"),
        ("Gym", "dumbbell.fill"),
        ("Airport", "airplane"),
        ("Other", "mappin.circle.fill"),
    ]
}
