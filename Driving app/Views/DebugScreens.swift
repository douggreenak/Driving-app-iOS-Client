#if DEBUG
import SwiftUI
import SwiftData
import CoreLocation

/// Headless-screenshot entry point. Renders one screen with seeded, in-memory sample data so
/// every view can be captured via `simctl` (env `UITEST_SCREEN`). Never compiled into release.
struct ScreenshotHarness: View {
    let screen: String

    @State private var container: ModelContainer = {
        let schema = Schema([DriveTrip.self, TrackPoint.self, ScheduledDrive.self,
                             GasEntry.self, Vehicle.self, UserSettings.self, SavedPlace.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }()

    var body: some View {
        Group {
            switch screen {
            case "detail":
                NavigationStack { TripDetailView(trip: seededTrip) }
            case "playback":
                NavigationStack { RoutePlaybackView(trip: seededTrip) }
            case "schedule":
                ScheduleView().onAppear {
                    SampleData.seedSchedules(into: container.mainContext)
                    SampleData.seedPlaces(into: container.mainContext)
                }
            case "newschedule":
                NewScheduledDriveView().onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "settings":
                SettingsView().onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "search":
                LocationSearchSheet(title: "Start", initialQuery: "Farmers Loop") { _ in }
                    .onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "searchcards":
                LocationSearchSheet(title: "Start") { _ in }
                    .onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "insights":
                DashboardView().onAppear {
                    SampleData.seedTrips(into: container.mainContext)
                    SampleData.seedSchedules(into: container.mainContext)
                }
            case "scheddetail":
                NavigationStack {
                    ScheduledDriveDetailView(drive: SampleData.makeSchedule(into: container.mainContext))
                        .onAppear { SampleData.seedPlaces(into: container.mainContext) }
                }
            case "drives":
                ScheduleView().onAppear {
                    SampleData.seedSchedules(into: container.mainContext)
                }
            case "trips":
                TripsListView().onAppear { _ = SampleData.makeTrip(into: container.mainContext) }
            case "gas":
                GasListView()
            case "editvehicle":
                NavigationStack { EditVehicleView(vehicle: seededVehicle) }
            case "track":
                LiveTrackingView(previewTracker: SampleData.inProgressTracker())
            case "summary":
                TripSummaryView(tracker: SampleData.inProgressTracker(),
                                vehicle: seededVehicle,
                                onSave: { _, _, _ in }, onDiscard: {})
            default:
                Text("Unknown screen: \(screen)")
            }
        }
        .modelContainer(container)
        .preferredColorScheme(.dark)
    }

    private var seededVehicle: Vehicle {
        let v = Vehicle(name: "My Subaru", make: "Subaru", model: "Outback", year: 2021, tankSize: 18.5, avgMpg: 28)
        container.mainContext.insert(v)
        return v
    }

    private var seededTrip: DriveTrip {
        // Seed a scheduled drive set too, so the schedule screen has content if navigated.
        SampleData.seedSchedules(into: container.mainContext)
        return SampleData.makeTrip(into: container.mainContext)
    }
}

enum SampleData {
    /// Anchorage waypoints (lat, lng, target mph) including a mid-route detour off the main road.
    private static let waypoints: [(Double, Double, Double)] = [
        (61.2181, -149.9003, 0),    // start, downtown
        (61.2150, -149.9050, 22),   // residential
        (61.2100, -149.9100, 34),   // arterial
        (61.2030, -149.9180, 38),
        (61.1980, -149.9300, 28),   // slow / lights
        (61.1955, -149.9260, 18),   // <-- detour bump off the efficient line
        (61.1930, -149.9380, 45),   // back on, ramp up
        (61.1870, -149.9550, 61),   // highway
        (61.1800, -149.9750, 63),
        (61.1760, -149.9900, 40),   // exit
        (61.1743, -149.9982, 0),    // arrive, airport area
    ]

    static func recordedPoints(base: Date = Date().addingTimeInterval(-1500)) -> [RecordedPoint] {
        var pts: [RecordedPoint] = []
        var t = base
        for i in 1..<waypoints.count {
            let a = waypoints[i - 1], b = waypoints[i]
            let from = CLLocationCoordinate2D(latitude: a.0, longitude: a.1)
            let to = CLLocationCoordinate2D(latitude: b.0, longitude: b.1)
            let meters = from.distanceMeters(to: to)
            let mph = max(8, (a.2 + b.2) / 2)
            let mps = mph * 0.44704
            let steps = max(4, Int(meters / 40))
            for s in 0..<steps {
                let f = Double(s) / Double(steps)
                let lat = a.0 + (b.0 - a.0) * f + Double((s % 3) - 1) * 0.00002
                let lng = a.1 + (b.1 - a.1) * f + Double((i % 3) - 1) * 0.00002
                let segMeters = meters / Double(steps)
                t = t.addingTimeInterval(segMeters / max(mps, 1))
                pts.append(RecordedPoint(
                    t: t,
                    coordinate: .init(latitude: lat, longitude: lng),
                    speed: mph + Double((s % 5) - 2),
                    course: -1,
                    accuracy: 6,
                    altitude: 120 + Double(i) * 18 + Double(s % 4) * 3
                ))
            }
        }
        return pts
    }

    static func makeTrip(into context: ModelContext) -> DriveTrip {
        let pts = recordedPoints()
        let first = pts.first!, last = pts.last!
        var meters = 0.0
        for i in 1..<pts.count { meters += pts[i - 1].coordinate.distanceMeters(to: pts[i].coordinate) }
        let miles = meters / 1609.34
        let secs = Int(last.t.timeIntervalSince(first.t))
        let segs = FuelModel.segments(from: pts)
        let gallons = FuelModel.gallons(segments: segs, ratedMpg: 28)

        // Scheduled to arrive well before the actual end → a >60 min delay (verifies h:m formatting).
        let scheduled: Date? = nil   // unscheduled trip → both endpoints green, "Apply" available

        let trip = DriveTrip(
            date: first.t, endDate: last.t,
            startAddress: "Downtown Anchorage", endAddress: "Ted Stevens Intl Airport",
            startLat: first.lat, startLng: first.lng, endLat: last.lat, endLng: last.lng,
            distance: miles, duration: secs, movingSeconds: Int(Double(secs) * 0.86),
            maxSpeed: pts.map(\.speed).max() ?? 0,
            avgSpeed: miles / (Double(secs) / 3600),
            notes: "Morning airport run", category: .commute,
            vehicleName: "My Subaru", vehicleMpg: 28, estimatedGallons: gallons,
            scheduledArrival: scheduled,
            matchedFraction: 0.88, usedRouteMatching: true,
            matchedPolyline: try? JSONEncoder().encode(pts.map { [$0.lat, $0.lng] })
        )
        context.insert(trip)
        for (i, p) in pts.enumerated() {
            let tp = TrackPoint(seq: i, t: p.t, lat: p.lat, lng: p.lng, speed: p.speed,
                                course: p.course, accuracy: p.accuracy, altitude: p.altitude, onRoad: (i % 9 != 0))
            tp.trip = trip
            context.insert(tp)
        }
        return trip
    }

    static func seedTrips(into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<DriveTrip>())) ?? []
        guard existing.isEmpty else { return }
        let cal = Calendar.current
        let cars = ["My Subaru", "Mom's CR-V"]
        let cats: [TripCategory] = [.commute, .work, .errand, .roadTrip, .leisure, .school]
        let delays = [0, 360, -180, 0, 600]  // some on time, some late, some early
        for k in 0..<10 {
            let date = cal.date(byAdding: .day, value: -(k * 11), to: Date()) ?? Date()
            let miles = Double(6 + k * 4)
            let mph = Double(26 + k % 5)
            let secs = Int(miles / mph * 3600) + 540
            let mpg = 25.0 + Double(k % 6)
            let end = date.addingTimeInterval(Double(secs))
            let scheduled = k % 3 == 0 ? end.addingTimeInterval(-Double(delays[k % delays.count])) : nil
            let trip = DriveTrip(
                date: date, endDate: end,
                startAddress: "Start point \(k)", endAddress: "Destination \(k)",
                startLat: 61.21, startLng: -149.90, endLat: 61.17, endLng: -149.99,
                distance: miles, duration: secs, movingSeconds: Int(Double(secs) * 0.85),
                maxSpeed: 52 + Double(k % 4) * 6, avgSpeed: miles / (Double(secs) / 3600),
                category: cats[k % cats.count], paidBy: k % 2 == 0 ? .parents : .myself,
                vehicleName: cars[k % cars.count],
                vehicleMpg: mpg, estimatedGallons: miles / mpg, scheduledArrival: scheduled)
            context.insert(trip)
        }
    }

    static func makeSchedule(into context: ModelContext) -> ScheduledDrive {
        if let existing = (try? context.fetch(FetchDescriptor<ScheduledDrive>()))?.first { return existing }
        let dep = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date()
        // Departs in the future (start on time → green) but with a tight 8-min budget the route
        // can't meet (arrival late → yellow), to show the dots colored independently.
        let d = ScheduledDrive(
            title: "Morning Commute", startAddress: "Downtown Anchorage", endAddress: "Ted Stevens Intl Airport",
            startLat: 61.2181, startLng: -149.9003, endLat: 61.1743, endLng: -149.9982,
            departure: dep, estimatedTravelTime: 22 * 60, scheduledArrival: dep.addingTimeInterval(8 * 60),
            repeatRule: .weekdays, category: .work, paidBy: .parents, vehicleName: "My Subaru")
        context.insert(d)
        return d
    }

    static func seedPlaces(into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<SavedPlace>())) ?? []
        guard existing.isEmpty else { return }
        let places = [
            SavedPlace(label: "Home", address: "1099 Farmers Loop Rd, Fairbanks, AK", lat: 64.86, lng: -147.74, icon: "house.fill", sortOrder: 0),
            SavedPlace(label: "Work", address: "Apex Engineering, Anchorage, AK", lat: 61.1743, lng: -149.9982, icon: "briefcase.fill", sortOrder: 1),
            SavedPlace(label: "School", address: "University of Alaska Anchorage", lat: 61.19, lng: -149.82, icon: "graduationcap.fill", sortOrder: 2),
        ]
        for p in places { context.insert(p) }
    }

    static func seedSchedules(into context: ModelContext) {
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 7, minute: 45, second: 0, of: Date()) ?? Date()
        let s1 = ScheduledDrive(
            title: "Morning Commute", startAddress: "Home", endAddress: "Apex Engineering",
            startLat: 61.2181, startLng: -149.9003, endLat: 61.1743, endLng: -149.9982,
            departure: morning, estimatedTravelTime: 22 * 60,
            scheduledArrival: morning.addingTimeInterval(22 * 60),
            repeatRule: .weekdays, category: .work, paidBy: .parents, vehicleName: "My Subaru")
        let evening = cal.date(bySettingHour: 17, minute: 30, second: 0, of: Date()) ?? Date()
        let s2 = ScheduledDrive(
            title: "Gym", startAddress: "Apex Engineering", endAddress: "The Alaska Club",
            startLat: 61.1743, startLng: -149.9982, endLat: 61.19, endLng: -149.88,
            departure: evening, estimatedTravelTime: 14 * 60,
            scheduledArrival: evening.addingTimeInterval(14 * 60),
            repeatRule: .weekly, category: .leisure, vehicleName: "My Subaru")
        s2.isCanceled = true   // demonstrate the CANCELED status

        // A drive whose predicted travel (30 min) exceeds its scheduled budget (20 min) → LATE.
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let s3 = ScheduledDrive(
            title: "Lunch Run", startAddress: "Office", endAddress: "Downtown Café",
            startLat: 61.17, startLng: -149.99, endLat: 61.22, endLng: -149.88,
            departure: noon, estimatedTravelTime: 30 * 60,
            scheduledArrival: noon.addingTimeInterval(20 * 60),
            repeatRule: .daily, category: .errand, vehicleName: "My Subaru")

        // A one-time drive whose scheduled window was 5 hours ago and was never started → LATE.
        let pastDep = cal.date(byAdding: .hour, value: -5, to: Date()) ?? Date()
        let s4 = ScheduledDrive(
            title: "Vet Appointment", startAddress: "Home", endAddress: "Pet Clinic",
            startLat: 61.21, startLng: -149.90, endLat: 61.15, endLng: -149.85,
            departure: pastDep, estimatedTravelTime: 18 * 60,
            scheduledArrival: pastDep.addingTimeInterval(18 * 60),
            repeatRule: .none, category: .errand, vehicleName: "My Subaru")
        s4.lastStartedAt = pastDep.addingTimeInterval(120)  // was actually driven → DEPARTED

        context.insert(s1)
        context.insert(s2)
        context.insert(s3)
        context.insert(s4)
    }

    @MainActor
    static func inProgressTracker() -> LocationTracker {
        let t = LocationTracker()
        let pts = recordedPoints(base: Date().addingTimeInterval(-720))
        let half = Array(pts.prefix(pts.count * 6 / 10))
        t.points = half
        t.isTracking = true
        t.elapsedSeconds = 720
        t.movingSeconds = 612
        t.currentSpeed = 38
        t.maxSpeed = 63
        var meters = 0.0
        for i in 1..<half.count { meters += half[i - 1].coordinate.distanceMeters(to: half[i].coordinate) }
        t.totalDistance = meters
        t.currentLocation = half.last?.coordinate
        t.destination = .init(latitude: 61.1743, longitude: -149.9982)
        t.destinationName = "Apex Engineering"
        t.scheduledArrival = Date().addingTimeInterval(8 * 60)  // tight — will show a small delay
        t.plannedCategory = .work
        return t
    }
}
#endif
