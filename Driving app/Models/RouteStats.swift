import Foundation
import CoreLocation

/// A "trip type": every recorded trip that went from one place to another (e.g. Home → Shop).
/// Built only from trips already in the store — places are named from saved places when one is
/// nearby, else the trip's own address; nothing is invented.
struct RouteSummary: Identifiable {
    var from: String
    var to: String
    var trips: [DriveTrip]            // newest first
    var id: String { "\(from)→\(to)" }

    var count: Int { trips.count }
    /// Recorded trips only for timing (a manually-entered drive's duration is what the user typed).
    private var timed: [DriveTrip] {
        let t = trips.filter { !$0.isManualEntry && $0.duration > 0 }
        return t.isEmpty ? trips.filter { $0.duration > 0 } : t
    }
    var avgSeconds: Int { timed.isEmpty ? 0 : timed.reduce(0) { $0 + $1.duration } / timed.count }
    var fastest: DriveTrip? { timed.min { $0.duration < $1.duration } }
    var slowest: DriveTrip? { timed.max { $0.duration < $1.duration } }
    var avgMiles: Double { trips.isEmpty ? 0 : trips.reduce(0) { $0 + $1.distance } / Double(trips.count) }
    var minMiles: Double { trips.map(\.distance).min() ?? 0 }
    var maxMiles: Double { trips.map(\.distance).max() ?? 0 }
    var totalMiles: Double { trips.reduce(0) { $0 + $1.distance } }
    var totalGallons: Double { trips.reduce(0) { $0 + $1.estimatedGallons } }
    var avgMph: Double {
        let s = timed.reduce(0) { $0 + $1.duration }
        return s > 0 ? timed.reduce(0.0) { $0 + $1.distance } / (Double(s) / 3600) : 0
    }
    var lastDriven: Date? { trips.first?.date }
    /// Scheduled-and-graded trips only.
    var onTimePercent: Double? {
        let graded = trips.compactMap(\.delaySeconds)
        guard !graded.isEmpty else { return nil }
        return Double(graded.filter { $0 <= 90 }.count) / Double(graded.count) * 100
    }
    /// Departure hour (0–23) with the lowest average duration, needing ≥2 trips in that hour.
    var bestDepartureHour: (hour: Int, avgSeconds: Int)? {
        let byHour = Dictionary(grouping: timed, by: { Calendar.current.component(.hour, from: $0.date) })
        return byHour.filter { $0.value.count >= 2 }
            .map { (hour: $0.key, avgSeconds: $0.value.reduce(0) { $0 + $1.duration } / $0.value.count) }
            .min { $0.avgSeconds < $1.avgSeconds }
    }
}

enum RouteStats {
    /// Short display name for one end of a trip.
    static func name(_ coord: CLLocationCoordinate2D, _ address: String, places: [SavedPlace]) -> String {
        let first = address.split(separator: ",").first.map(String.init) ?? address
        return PlaceNamer.name(for: coord, fallback: first.trimmingCharacters(in: .whitespaces), in: places)
    }

    /// Every distinct from→to pair in `trips`, most-driven first.
    static func summaries(trips: [DriveTrip], places: [SavedPlace]) -> [RouteSummary] {
        var groups: [String: RouteSummary] = [:]
        for t in trips.sorted(by: { $0.date > $1.date }) {
            let f = name(t.startCoordinate, t.startAddress, places: places)
            let e = name(t.endCoordinate, t.endAddress, places: places)
            guard f.lowercased() != e.lowercased() else { continue }   // a loop isn't a "route"
            let key = "\(f)→\(e)"
            if groups[key] == nil { groups[key] = RouteSummary(from: f, to: e, trips: []) }
            groups[key]!.trips.append(t)
        }
        return groups.values.sorted { ($0.count, $0.lastDriven ?? .distantPast) > ($1.count, $1.lastDriven ?? .distantPast) }
    }
}
