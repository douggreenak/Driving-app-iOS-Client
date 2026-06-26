import Foundation
import SwiftData

enum PaidBy: String, Codable, CaseIterable {
    case myself = "SELF"
    case parents = "PARENTS"

    var label: String {
        switch self {
        case .myself: "Me"
        case .parents: "Parents"
        }
    }
}

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
}

@Model
final class Trip {
    var date: Date
    var startAddress: String
    var endAddress: String
    var startLat: Double
    var startLng: Double
    var endLat: Double
    var endLng: Double
    var distance: Double
    var duration: Int
    var notes: String?
    var categoryRaw: String
    var isFavorite: Bool
    @Relationship(deleteRule: .cascade, inverse: \GasEntry.trip)
    var gasEntries: [GasEntry]

    var category: TripCategory {
        get { TripCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    init(
        date: Date = .now,
        startAddress: String,
        endAddress: String,
        startLat: Double,
        startLng: Double,
        endLat: Double,
        endLng: Double,
        distance: Double,
        duration: Int,
        notes: String? = nil,
        category: TripCategory = .other,
        isFavorite: Bool = false
    ) {
        self.date = date
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.startLat = startLat
        self.startLng = startLng
        self.endLat = endLat
        self.endLng = endLng
        self.distance = distance
        self.duration = duration
        self.notes = notes
        self.categoryRaw = category.rawValue
        self.isFavorite = isFavorite
        self.gasEntries = []
    }
}

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
    var trip: Trip?

    var paidBy: PaidBy {
        get { PaidBy(rawValue: paidByRaw) ?? .myself }
        set { paidByRaw = newValue.rawValue }
    }

    var fuelType: FuelType {
        get { FuelType(rawValue: fuelTypeRaw) ?? .regular }
        set { fuelTypeRaw = newValue.rawValue }
    }

    init(
        date: Date = .now,
        gallons: Double,
        pricePerGallon: Double,
        paidBy: PaidBy,
        fuelType: FuelType = .regular,
        stationName: String? = nil,
        odometer: Double? = nil,
        trip: Trip? = nil
    ) {
        self.date = date
        self.gallons = gallons
        self.pricePerGallon = pricePerGallon
        self.totalCost = gallons * pricePerGallon
        self.paidByRaw = paidBy.rawValue
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

    init(monthlyBudget: Double = 0, distanceUnit: String = "miles") {
        self.monthlyBudget = monthlyBudget
        self.distanceUnit = distanceUnit
    }
}
