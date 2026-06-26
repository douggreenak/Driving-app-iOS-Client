import Foundation

struct APIClient {
    static let baseURL = "https://drive-tracker-gamma.vercel.app"

    // MARK: - Trips

    static func fetchTrips() async throws -> [APITrip] {
        let data = try await get("/api/trips")
        return try JSONDecoder.api.decode([APITrip].self, from: data)
    }

    static func createTrip(_ trip: APITripCreate) async throws -> APITrip {
        let body = try JSONEncoder.api.encode(trip)
        let data = try await post("/api/trips", body: body)
        return try JSONDecoder.api.decode(APITrip.self, from: data)
    }

    static func deleteTrip(id: String) async throws {
        let body = try JSONEncoder.api.encode(["id": id])
        _ = try await request("DELETE", "/api/trips", body: body)
    }

    static func patchTrip(id: String, isFavorite: Bool) async throws {
        let body = try JSONEncoder.api.encode(["id": id, "isFavorite": isFavorite ? "true" : "false"])
        _ = try await request("PATCH", "/api/trips", body: body)
    }

    // MARK: - Gas

    static func fetchGasEntries() async throws -> [APIGasEntry] {
        let data = try await get("/api/gas")
        return try JSONDecoder.api.decode([APIGasEntry].self, from: data)
    }

    static func createGasEntry(_ entry: APIGasEntryCreate) async throws -> APIGasEntry {
        let body = try JSONEncoder.api.encode(entry)
        let data = try await post("/api/gas", body: body)
        return try JSONDecoder.api.decode(APIGasEntry.self, from: data)
    }

    static func deleteGasEntry(id: String) async throws {
        let body = try JSONEncoder.api.encode(["id": id])
        _ = try await request("DELETE", "/api/gas", body: body)
    }

    // MARK: - Stats

    static func fetchStats() async throws -> APIStats {
        let data = try await get("/api/stats")
        return try JSONDecoder.api.decode(APIStats.self, from: data)
    }

    // MARK: - HTTP Helpers

    private static func get(_ path: String) async throws -> Data {
        try await request("GET", path, body: nil)
    }

    private static func post(_ path: String, body: Data) async throws -> Data {
        try await request("POST", path, body: body)
    }

    private static func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}

// MARK: - API Models

struct APITrip: Codable, Identifiable {
    let id: String
    let date: String
    let startAddress: String
    let endAddress: String
    let startLat: Double
    let startLng: Double
    let endLat: Double
    let endLng: Double
    let distance: Double
    let duration: Int
    let notes: String?
    let category: String
    let isFavorite: Bool
    let gasEntries: [APIGasEntry]?

    var parsedDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: date) ?? Date()
    }

    var tripCategory: TripCategory {
        TripCategory(rawValue: category) ?? .other
    }
}

struct APITripCreate: Codable {
    let date: String
    let startAddress: String
    let endAddress: String
    let startLat: Double
    let startLng: Double
    let endLat: Double
    let endLng: Double
    let distance: Double
    let duration: Int
    let notes: String?
    let category: String
}

struct APIGasEntry: Codable, Identifiable {
    let id: String
    let date: String
    let gallons: Double
    let pricePerGallon: Double
    let totalCost: Double
    let paidBy: String
    let fuelType: String
    let stationName: String?
    let odometer: Double?

    var parsedDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: date) ?? Date()
    }

    var paidByEnum: PaidBy {
        PaidBy(rawValue: paidBy) ?? .myself
    }

    var fuelTypeEnum: FuelType {
        FuelType(rawValue: fuelType) ?? .regular
    }
}

struct APIGasEntryCreate: Codable {
    let date: String
    let gallons: Double
    let pricePerGallon: Double
    let paidBy: String
    let fuelType: String
    let stationName: String?
    let odometer: Double?
}

struct APIStats: Codable {
    let totalTrips: Int
    let totalMiles: Double
    let totalGallons: Double
    let totalSpent: Double
    let selfPaid: Double
    let parentsPaid: Double
    let avgMpg: Double
    let costPerMile: Double
    let avgPricePerGallon: Double
    let monthlySpent: Double
    let weeklyMiles: Double
    let weeklyTrips: Int
    let categoryCounts: [String: Int]
    let monthlyBudget: Double
    let favoriteCount: Int
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
}
