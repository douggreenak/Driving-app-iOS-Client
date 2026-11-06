import Foundation

struct APIClient {
    static let baseURL = "https://drive-tracker-gamma.vercel.app"

    // Shared secret authenticating this app to the web API. Injected at build
    // time from Secrets.xcconfig (gitignored) → Info.plist `APIKey`, so the key
    // is never a literal in committed source. Must match the backend's API_KEY.
    static let apiKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "APIKey") as? String ?? ""
    }()

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

    /// Update just the payer on an already-synced trip (used to backfill `paidBy` onto historical
    /// trips that were uploaded before the server had the column). Non-destructive: updates the
    /// existing row by id, never creates or deletes.
    /// Every trip field the web API lets a client edit after creation.
    struct TripFieldsPatch: Codable {
        let id: String
        let isFavorite: Bool
        let category: String
        let notes: String
        let paidBy: String
        let date: String
        let startAddress: String
        let endAddress: String
        let startLat: Double, startLng: Double, endLat: Double, endLng: Double
        let stops: [RouteStop]
    }

    static func patchTripFields(_ patch: TripFieldsPatch) async throws {
        let body = try JSONEncoder.api.encode(patch)
        _ = try await request("PATCH", "/api/trips", body: body)
    }

    static func patchTripPaidBy(id: String, paidBy: String) async throws {
        let body = try JSONEncoder.api.encode(["id": id, "paidBy": paidBy])
        _ = try await request("PATCH", "/api/trips", body: body)
    }

    /// Update a synced trip's stops (multi-stop annotations added after the drive was recorded).
    static func patchTripStops(id: String, stops: [RouteStop]) async throws {
        struct Body: Codable { let id: String; let stops: [RouteStop] }
        let body = try JSONEncoder.api.encode(Body(id: id, stops: stops))
        _ = try await request("PATCH", "/api/trips", body: body)
    }

    /// Push the rewritten geometry + stats after a trip is trimmed (start/end recomputed), including
    /// the new endpoint coordinates & addresses so the web map/labels stay consistent.
    static func patchTripTrim(id: String, date: String, distance: Double, duration: Int,
                              startAddress: String, endAddress: String,
                              startLat: Double, startLng: Double, endLat: Double, endLng: Double,
                              routeEncoded: String) async throws {
        struct Body: Codable {
            let id: String; let date: String; let distance: Double; let duration: Int
            let startAddress: String; let endAddress: String
            let startLat: Double; let startLng: Double; let endLat: Double; let endLng: Double
            let routeEncoded: String
        }
        let body = try JSONEncoder.api.encode(Body(
            id: id, date: date, distance: distance, duration: duration,
            startAddress: startAddress, endAddress: endAddress,
            startLat: startLat, startLng: startLng, endLat: endLat, endLng: endLng,
            routeEncoded: routeEncoded))
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

    struct GasPatch: Codable {
        let id: String
        let date: String
        let gallons: Double
        let pricePerGallon: Double
        let paidBy: String
        let fuelType: String
        let stationName: String?
        let odometer: Double?
    }

    /// Edit a fill-up in place. The web API's PATCH only accepts the built-in SELF/PARENTS payers, so
    /// a custom payer group is saved by re-creating the row instead (see `GasEditView`).
    static func patchGasEntry(_ patch: GasPatch) async throws {
        let body = try JSONEncoder.api.encode(patch)
        _ = try await request("PATCH", "/api/gas", body: body)
    }

    static func deleteGasEntry(id: String) async throws {
        let body = try JSONEncoder.api.encode(["id": id])
        _ = try await request("DELETE", "/api/gas", body: body)
    }

    // MARK: - Scheduled drives

    static func fetchScheduledDrives() async throws -> [APIScheduledDrive] {
        let data = try await get("/api/scheduled")
        return try JSONDecoder.api.decode([APIScheduledDrive].self, from: data)
    }

    static func createScheduledDrive(_ drive: APIScheduledDrivePayload) async throws -> APIScheduledDrive {
        let body = try JSONEncoder.api.encode(drive)
        let data = try await post("/api/scheduled", body: body)
        return try JSONDecoder.api.decode(APIScheduledDrive.self, from: data)
    }

    static func updateScheduledDrive(_ drive: APIScheduledDrivePayload) async throws {
        let body = try JSONEncoder.api.encode(drive)
        _ = try await request("PATCH", "/api/scheduled", body: body)
    }

    static func deleteScheduledDrive(id: String) async throws {
        let body = try JSONEncoder.api.encode(["id": id])
        _ = try await request("DELETE", "/api/scheduled", body: body)
    }

    // MARK: - Stats

    static func fetchStats() async throws -> APIStats {
        let data = try await get("/api/stats")
        return try JSONDecoder.api.decode(APIStats.self, from: data)
    }

    // MARK: - HTTP Helpers

    static func get(_ path: String) async throws -> Data {
        try await request("GET", path, body: nil)
    }

    static func post(_ path: String, body: Data) async throws -> Data {
        try await request("POST", path, body: body)
    }

    enum APIError: Error {
        case http(Int)
        /// A write was attempted against the LIVE server from a simulator debug build — blocked so
        /// test runs can never push test data into real user data. See `request`.
        case writeBlockedInDebug
    }

    /// Where requests go. Simulator debug runs can point at a local mock server by setting
    /// `DRIVE_API_BASE_URL`; everything else uses the live backend.
    static var effectiveBaseURL: String {
        #if DEBUG
        if let o = ProcessInfo.processInfo.environment["DRIVE_API_BASE_URL"], !o.isEmpty { return o }
        #endif
        return baseURL
    }

    static func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        // SAFETY: a debug build running in the iOS Simulator must never WRITE to the live server —
        // test data created while exercising the app would otherwise land in the real database.
        // Reads (GET) are still allowed (they only copy real data down into the simulator's local
        // store), and writes work normally against a mock server set via `DRIVE_API_BASE_URL`.
        #if DEBUG && targetEnvironment(simulator)
        if method != "GET", effectiveBaseURL == baseURL { throw APIError.writeBlockedInDebug }
        #endif
        var req = URLRequest(url: URL(string: effectiveBaseURL + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = body
        // Reads of small lists fail fast; anything that carries a payload (trip + track uploads, full
        // restores) gets room to finish. A 12 s limit used to cut full-fidelity uploads off mid-flight
        // on a weak cell connection — the server often still saved the row, the phone never heard
        // back, and the retry then uploaded the same drive a second time.
        let heavy = method != "GET" || path.contains("full=true") || path.contains("/points")
        req.timeoutInterval = heavy ? 60 : 15
        // Every "pull to refresh" in the app ultimately calls a GET here. `URLSessionConfiguration
        // .default` consults `URLCache.shared` under `.useProtocolCachePolicy`, so if this backend
        // ever answers with a revalidating/cacheable `Cache-Control`, a refresh could silently be
        // served the previous response with no network round-trip at all — indistinguishable from
        // "refreshing does nothing". Reads should always hit the network; writes are unaffected
        // (POST/PATCH/DELETE responses were never cached to begin with).
        if method == "GET" { req.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, response) = try await (heavy ? heavySession : session).data(for: req)
        // Treat non-2xx as a real failure so error bodies aren't decoded as data and a failed
        // create/delete/patch surfaces to the caller instead of looking like success.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        return data
    }

    private static let heavySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
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
    let paidBy: String?
    let stops: [RouteStop]?
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
    let paidBy: String
    var stops: [RouteStop] = []
    var routeEncoded: String? = nil
    // Full-fidelity fields the backend stores (see `/api/trips` POST) so a trip can be fully
    // restored on a fresh install — not just summarized.
    var endDate: String? = nil
    var movingSeconds: Int? = nil
    var maxSpeed: Double? = nil
    var avgSpeed: Double? = nil
    var name: String? = nil
    var matchedPolyline: String? = nil
    var matchedFraction: Double? = nil
    var usedRouteMatching: Bool? = nil
    var isFavorite: Bool? = nil
    var vehicleName: String? = nil
    var vehicleMpg: Double? = nil
    var estimatedGallons: Double? = nil
    var scheduledDeparture: String? = nil
    var scheduledArrival: String? = nil
    var journeyId: String? = nil
    var legIndex: Int? = nil
    var legTotal: Int? = nil
    var isManualEntry: Bool? = nil
}

// MARK: Scheduled drives

/// A scheduled drive as returned by the backend (dates are ISO-8601 strings).
struct APIScheduledDrive: Codable, Identifiable {
    let id: String
    let title: String
    let startAddress: String
    let endAddress: String
    let startLat: Double
    let startLng: Double
    let endLat: Double
    let endLng: Double
    let departure: String
    let estimatedTravelTime: Int
    let scheduledArrival: String
    let repeatRule: String
    let category: String
    let paidBy: String
    let vehicleName: String?
    let notes: String?
    let isEnabled: Bool
    let isCanceled: Bool
    let lastStartedAt: String?
    let lastCompletedAt: String?
    let skippedOccurrences: [Double]
    let stops: [RouteStop]?
}

/// Payload for creating (id nil) or updating (id set) a scheduled drive.
struct APIScheduledDrivePayload: Codable {
    var id: String?
    let title: String
    let startAddress: String
    let endAddress: String
    let startLat: Double
    let startLng: Double
    let endLat: Double
    let endLng: Double
    let departure: String
    let estimatedTravelTime: Int
    let scheduledArrival: String
    let repeatRule: String
    let category: String
    let paidBy: String
    let vehicleName: String?
    let notes: String?
    let isEnabled: Bool
    let isCanceled: Bool
    let lastStartedAt: String?
    let lastCompletedAt: String?
    let skippedOccurrences: [Double]
    /// Occurrences canceled "just this once" (epoch seconds). The web schema doesn't persist these
    /// yet, so the server ignores the field — cancellation is local-first for now.
    let canceledOccurrences: [Double]
    let stops: [RouteStop]
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
    let vehicleName: String?

    var parsedDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: date) ?? Date()
    }

    /// Resolve this entry's stored payer key against the live group list — see
    /// `PayerGroup.resolve(key:in:)`. Falls back to a neutral "Unknown" display so a fill-up whose
    /// payer group was since archived/removed still shows *something* instead of silently reading
    /// as "Me".
    func payer(in groups: [PayerGroup]) -> PayerDisplay {
        PayerGroup.resolve(key: paidBy, in: groups)
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
    let vehicleName: String?
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
