import Foundation

/// Flighty-style driving analytics, computed purely from recorded drives (no network).
struct DrivingStats {
    struct CarStat: Identifiable {
        var id: String { name }
        var name: String
        var miles: Double
        var seconds: Int
        var gallons: Double
        var count: Int
    }
    struct CategoryStat: Identifiable {
        var id: String { categoryRaw }
        var categoryRaw: String
        var miles: Double
        var seconds: Int
        var count: Int
        var category: TripCategory { TripCategory(rawValue: categoryRaw) ?? .other }
    }
    struct MonthStat: Identifiable {
        var id: Date { monthStart }
        var monthStart: Date
        var miles: Double
    }
    struct Record {
        var title: String
        var value: String
        var icon: String
    }
    /// Miles/gallons/drives for one payer group (keyed by `PayerGroup.key` in `byPayer`).
    struct PayerBucket {
        var miles = 0.0
        var gallons = 0.0
        var drives = 0
        /// Gallons billable at the current pump price: only fuel burned since each car's last
        /// fill-up. Cost is computed from this so the price applies to the current tank only.
        var billableGallons = 0.0
    }

    // Totals
    var driveCount = 0
    var totalMiles = 0.0
    var totalSeconds = 0
    var totalGallons = 0.0

    /// Paid-by breakdown (the app's core: which drives which group covers), keyed by `PayerGroup.key`.
    /// Every payer group that ever appears on a trip gets an entry — including one whose group has
    /// since been archived/deleted, so historical totals never silently vanish.
    var byPayer: [String: PayerBucket] = [:]
    var totalBillableGallons = 0.0

    /// Bucket for `key`, or an all-zero bucket if it never appeared in any trip (never crashes/nils).
    func bucket(for key: String) -> PayerBucket { byPayer[key] ?? PayerBucket() }
    func gallons(for key: String) -> Double { bucket(for: key).gallons }
    func miles(for key: String) -> Double { bucket(for: key).miles }
    func drives(for key: String) -> Int { bucket(for: key).drives }
    func billableGallons(for key: String) -> Double { bucket(for: key).billableGallons }
    func cost(for key: String, pricePerGallon: Double) -> Double { billableGallons(for: key) * pricePerGallon }
    func totalCost(pricePerGallon: Double) -> Double { totalBillableGallons * pricePerGallon }

    var avgMph: Double { totalSeconds > 0 ? totalMiles / (Double(totalSeconds) / 3600) : 0 }
    var avgDriveMiles: Double { driveCount > 0 ? totalMiles / Double(driveCount) : 0 }
    var avgMpg: Double { totalGallons > 0 ? totalMiles / totalGallons : 0 }

    // Records
    var longestMiles = 0.0
    var longestSeconds = 0
    var topSpeed = 0.0
    var bestMpg = 0.0
    var worstMpg = 0.0

    // Breakdowns
    var byCar: [CarStat] = []
    var byCategory: [CategoryStat] = []
    var monthly: [MonthStat] = []

    // On-time performance (scheduled + completed drives)
    var scheduledCount = 0
    var onTimeCount = 0
    var totalDelaySeconds = 0

    var onTimePercent: Double { scheduledCount > 0 ? Double(onTimeCount) / Double(scheduledCount) * 100 : 0 }
    var avgDelaySeconds: Int? { scheduledCount > 0 ? totalDelaySeconds / scheduledCount : nil }

    init() {}

    /// - Parameter fillUps: per-car (`vehicleName` → last fill-up date). Fuel burned on or after a
    ///   car's last fill-up is "billable" at the current price; earlier fuel was paid for already.
    init(trips: [DriveTrip], fillUps: [String: Date] = [:]) {
        guard !trips.isEmpty else { return }
        driveCount = trips.count

        var cars: [String: CarStat] = [:]
        var cats: [String: CategoryStat] = [:]
        var months: [Date: Double] = [:]
        let cal = Calendar.current

        for t in trips {
            totalMiles += t.distance
            totalSeconds += t.duration
            totalGallons += t.estimatedGallons

            // Billable only if on/after this car's last fill-up (or the car has no recorded fill-up).
            let fillUp = t.vehicleName.flatMap { fillUps[$0] }
            let billable = fillUp == nil || t.date >= fillUp!
            if billable { totalBillableGallons += t.estimatedGallons }

            var bucket = byPayer[t.paidByRaw] ?? PayerBucket()
            bucket.miles += t.distance; bucket.gallons += t.estimatedGallons; bucket.drives += 1
            if billable { bucket.billableGallons += t.estimatedGallons }
            byPayer[t.paidByRaw] = bucket

            longestMiles = max(longestMiles, t.distance)
            longestSeconds = max(longestSeconds, t.duration)
            topSpeed = max(topSpeed, t.maxSpeed)

            if t.estimatedGallons > 0.01, t.distance > 0.1 {
                let mpg = t.distance / t.estimatedGallons
                bestMpg = bestMpg == 0 ? mpg : max(bestMpg, mpg)
                worstMpg = worstMpg == 0 ? mpg : min(worstMpg, mpg)
            }

            let car = t.vehicleName ?? "Unknown car"
            var cs = cars[car] ?? CarStat(name: car, miles: 0, seconds: 0, gallons: 0, count: 0)
            cs.miles += t.distance; cs.seconds += t.duration; cs.gallons += t.estimatedGallons; cs.count += 1
            cars[car] = cs

            var ct = cats[t.categoryRaw] ?? CategoryStat(categoryRaw: t.categoryRaw, miles: 0, seconds: 0, count: 0)
            ct.miles += t.distance; ct.seconds += t.duration; ct.count += 1
            cats[t.categoryRaw] = ct

            let comps = cal.dateComponents([.year, .month], from: t.date)
            if let monthStart = cal.date(from: comps) {
                months[monthStart, default: 0] += t.distance
            }

            if let delay = t.delaySeconds {
                scheduledCount += 1
                totalDelaySeconds += delay
                if abs(delay) <= 90 { onTimeCount += 1 }
            }
        }

        byCar = cars.values.sorted { $0.seconds > $1.seconds }
        byCategory = cats.values.sorted { $0.miles > $1.miles }
        monthly = months.map { MonthStat(monthStart: $0.key, miles: $0.value) }
            .sorted { $0.monthStart < $1.monthStart }
            .suffix(12)
            .map { $0 }
    }

    /// Headline records for the insights "Records" strip.
    var records: [Record] {
        [
            Record(title: "Longest drive", value: String(format: "%.0f mi", longestMiles), icon: "arrow.left.and.right"),
            Record(title: "Longest time", value: Self.duration(longestSeconds), icon: "clock.fill"),
            Record(title: "Top speed", value: String(format: "%.0f mph", topSpeed), icon: "gauge.with.dots.needle.67percent"),
            Record(title: "Best MPG", value: bestMpg > 0 ? String(format: "%.0f", bestMpg) : "—", icon: "leaf.fill"),
        ]
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
