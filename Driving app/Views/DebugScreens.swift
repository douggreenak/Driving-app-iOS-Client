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
                             GasEntry.self, Vehicle.self, UserSettings.self, SavedPlace.self,
                             PayerGroup.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let c = try! ModelContainer(for: schema, configurations: config)
        PayerGroupStore.seedIfNeeded(context: c.mainContext)
        return c
    }()
    /// Every screenshot case renders a plain `LiveTrackingView` without going through
    /// `ActiveDriveController.start(...)` — it still needs *some* controller in the environment since
    /// `LiveTrackingView` reads one for its minimize button, even though minimizing is never exercised
    /// in a screenshot fixture.
    @State private var activeDrive = ActiveDriveController()

    var body: some View {
        Group {
            switch screen {
            case "detail":
                NavigationStack { TripDetailView(trip: seededTrip) }
            case "playback":
                NavigationStack { RoutePlaybackView(trip: seededTrip) }
            case "drive", "schedule", "drives", "home":
                DriveHomeView().onAppear {
                    SampleData.seedSchedules(into: container.mainContext)
                    SampleData.seedPlaces(into: container.mainContext)
                }
            case "newschedule":
                NewScheduledDriveView().onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "predict":
                RoutePredictView().onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "stats", "dashboard":
                StatsView().onAppear {
                    SampleData.seedTrips(into: container.mainContext)
                    SampleData.seedSchedules(into: container.mainContext)
                    SampleData.seedPlaces(into: container.mainContext)
                }
            case "settings":
                SettingsView().onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "search":
                LocationSearchSheet(title: "Start", initialQuery: "Farmers Loop") { _ in }
                    .onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "searchcards":
                LocationSearchSheet(title: "Start") { _ in }
                    .onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "insights":
                StatsView().onAppear {
                    SampleData.seedTrips(into: container.mainContext)
                    SampleData.seedSchedules(into: container.mainContext)
                    SampleData.seedPlaces(into: container.mainContext)
                }
            case "scheddetail":
                NavigationStack {
                    ScheduledDriveDetailView(drive: SampleData.makeSchedule(into: container.mainContext))
                        .onAppear { SampleData.seedPlaces(into: container.mainContext) }
                }
            case "cancelbug":
                DriveHomeView().onAppear {
                    SampleData.seedCanceledUpNext(into: container.mainContext)
                    SampleData.seedPlaces(into: container.mainContext)
                }
            case "cancelrollforward":
                DriveHomeView().onAppear {
                    SampleData.seedCanceledPastWindow(into: container.mainContext)
                    SampleData.seedPlaces(into: container.mainContext)
                }
            case "trips":
                TripsListView().onAppear { _ = SampleData.makeTrip(into: container.mainContext) }
            case "journey":
                TripsListView().onAppear {
                    _ = SampleData.makeJourney(into: container.mainContext)
                    SampleData.seedPlaces(into: container.mainContext)
                }
            case "journeydetail":
                NavigationStack { TripDetailView(trip: seededJourneyLeg) }
                    .onAppear { SampleData.seedPlaces(into: container.mainContext) }
            case "gas":
                GasListView()
            case "editvehicle":
                NavigationStack { EditVehicleView(vehicle: seededVehicle) }
            case "track":
                LiveTrackingView(previewTracker: SampleData.inProgressTracker())
            case "gototrack":
                LiveTrackingView(goTo: QuickTrip(
                    name: "Home",
                    coordinate: CLLocationCoordinate2D(latitude: 61.2181, longitude: -149.9003),
                    travelSeconds: 15 * 60))
            case "trackleg":
                LiveTrackingView(previewTracker: SampleData.multiLegTracker(paused: false))
            case "trackpaused":
                LiveTrackingView(previewTracker: SampleData.multiLegTracker(paused: true))
            case "trackstart":
                LiveTrackingView(previewTracker: SampleData.idleTracker(withDestination: false))
            case "trackdest":
                LiveTrackingView(previewTracker: SampleData.idleTracker(withDestination: true))
            case "trackopen":
                LiveTrackingView(previewTracker: SampleData.openDriveTracker())
            case "gotostatus":
                LiveTrackingView(previewTracker: SampleData.goToStatusTracker())
            case "statuschips":
                StatusChipGallery()
            case "applyschedule":
                ApplyScheduleSheet(trip: seededTrip)
                    .onAppear { SampleData.seedSchedules(into: container.mainContext) }
            case "trim":
                TripTrimView(trip: seededTrip)
            case "summary":
                TripSummaryView(tracker: SampleData.inProgressTracker(),
                                vehicle: seededVehicle,
                                onSave: { _, _, _ in }, onDiscard: {})
            default:
                Text("Unknown screen: \(screen)")
            }
        }
        .modelContainer(container)
        .environment(activeDrive)
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

    /// The middle leg of a seeded linked journey, for the journey-card detail screenshot.
    private var seededJourneyLeg: DriveTrip {
        let legs = SampleData.makeJourney(into: container.mainContext)
        return legs.count >= 2 ? legs[1] : (legs.first ?? SampleData.makeTrip(into: container.mainContext))
    }
}

/// A location-free gallery of the live driving status chips, for verifying that a "Go to" / scheduled
/// drive shows a real on-time verdict (and a neutral EN ROUTE while awaiting the first fix) instead of
/// the old misleading "NO SCHEDULE".
private struct StatusChipGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Live drive status").font(.title2.bold())
            row("Go to · awaiting ETA", StatusChip(status: .liveEnRoute))
            row("Go to · on time", StatusChip(status: .live(delaySeconds: 0)))
            row("Go to · early", StatusChip(status: .live(delaySeconds: -9 * 60)))
            row("Go to · delayed", StatusChip(status: .live(delaySeconds: 12 * 60)))
            Divider().overlay(.secondary)
            Text("Saved trip status").font(.headline)
            row("Arrived on time", StatusChip(status: .forTrip(delaySeconds: 30)))
            row("Arrived early", StatusChip(status: .forTrip(delaySeconds: -7 * 60)))
            row("Arrived late", StatusChip(status: .forTrip(delaySeconds: 22 * 60)))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(.black)
    }

    private func row(_ label: String, _ chip: StatusChip) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.white)
            Spacer()
            chip
        }
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

    /// A recorded multi-stop drive saved as three separate, *linked* trips (one per leg) sharing a
    /// journey id — for verifying the linked-legs list rows and the journey card. Idempotent.
    @discardableResult
    static func makeJourney(into context: ModelContext) -> [DriveTrip] {
        if let existing = try? context.fetch(FetchDescriptor<DriveTrip>()),
           existing.contains(where: { $0.journeyID != nil }) {
            return existing.filter { $0.journeyID != nil }.sorted { $0.legIndex < $1.legIndex }
        }
        let jid = UUID()
        let allPts = recordedPoints(base: Date().addingTimeInterval(-3600))
        let n = allPts.count
        let cuts = [0, n / 3, 2 * n / 3, n]
        let names = [("Home", "Midtown Costco"),
                     ("Midtown Costco", "Spenard Post Office"),
                     ("Spenard Post Office", "Ted Stevens Intl Airport")]
        var trips: [DriveTrip] = []
        for i in 0..<3 {
            let seg = Array(allPts[cuts[i]..<cuts[i + 1]])
            guard seg.count >= 2, let first = seg.first, let last = seg.last else { continue }
            var meters = 0.0
            for k in 1..<seg.count { meters += seg[k - 1].coordinate.distanceMeters(to: seg[k].coordinate) }
            let miles = meters / 1609.34
            let secs = Int(last.t.timeIntervalSince(first.t))
            let gallons = FuelModel.gallons(segments: FuelModel.segments(from: seg), ratedMpg: 28)
            let trip = DriveTrip(
                date: first.t, endDate: last.t,
                startAddress: names[i].0, endAddress: names[i].1,
                startLat: first.lat, startLng: first.lng, endLat: last.lat, endLng: last.lng,
                distance: miles, duration: secs, movingSeconds: Int(Double(secs) * 0.85),
                maxSpeed: seg.map(\.speed).max() ?? 0, avgSpeed: secs > 0 ? miles / (Double(secs) / 3600) : 0,
                name: "Errand Run", category: .errand, paidBy: PayerGroup.parentsKey,
                vehicleName: "My Subaru", vehicleMpg: 28, estimatedGallons: gallons)
            trip.journeyID = jid
            trip.legIndex = i
            trip.legTotal = 3
            context.insert(trip)
            for (k, p) in seg.enumerated() {
                let tp = TrackPoint(seq: k, t: p.t, lat: p.lat, lng: p.lng, speed: p.speed,
                                    course: p.course, accuracy: p.accuracy, altitude: p.altitude, onRoad: true)
                tp.trip = trip
                context.insert(tp)
            }
            trips.append(trip)
        }
        return trips
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
                category: cats[k % cats.count], paidBy: k % 2 == 0 ? PayerGroup.parentsKey : PayerGroup.selfKey,
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
            repeatRule: .weekdays, category: .work, paidBy: PayerGroup.parentsKey, vehicleName: "My Subaru")
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

    /// Seed for the cancel-bug repro: a single daily drive whose *currently up-next* occurrence is
    /// canceled. A correct "Up Next" must NOT show this canceled occurrence.
    static func seedCanceledUpNext(into context: ModelContext) {
        // Departs 40 minutes from now (so its own occurrence today is the imminent one).
        let dep = Date().addingTimeInterval(40 * 60)
        let d = ScheduledDrive(
            title: "Grocery Run", startAddress: "Home", endAddress: "Fred Meyer",
            startLat: 61.2181, startLng: -149.9003, endLat: 61.19, endLng: -149.88,
            departure: dep, estimatedTravelTime: 12 * 60,
            scheduledArrival: dep.addingTimeInterval(12 * 60),
            repeatRule: .daily, category: .errand, paidBy: PayerGroup.parentsKey, vehicleName: "My Subaru")
        context.insert(d)
        // Cancel the exact occurrence that would otherwise be promoted to Up Next.
        if let up = d.upNextDeparture() { d.setOccurrenceCanceled(up, true) }
    }

    /// Regression seed for the narrowed cancel guard: a daily drive whose occurrence EARLIER TODAY
    /// (well past its window) was canceled. Up Next must roll forward to the next occurrence rather
    /// than staying hidden for the rest of the interval.
    static func seedCanceledPastWindow(into context: ModelContext) {
        let dep = Date().addingTimeInterval(-8 * 3600)   // 8h ago → past its ~6h window
        let d = ScheduledDrive(
            title: "School Run", startAddress: "Home", endAddress: "UAA",
            startLat: 61.2181, startLng: -149.9003, endLat: 61.19, endLng: -149.82,
            departure: dep, estimatedTravelTime: 12 * 60,
            scheduledArrival: dep.addingTimeInterval(12 * 60),
            repeatRule: .daily, category: .school, paidBy: PayerGroup.parentsKey, vehicleName: "My Subaru")
        context.insert(d)
        // Cancel the earlier-today occurrence (now clearly past its window).
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute], from: dep)
        if let todayOcc = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: Date()) {
            d.setOccurrenceCanceled(todayOcc, true)
        }
    }

    static func seedSchedules(into context: ModelContext) {
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 7, minute: 45, second: 0, of: Date()) ?? Date()
        let s1 = ScheduledDrive(
            title: "Morning Commute", startAddress: "Home", endAddress: "Apex Engineering",
            startLat: 61.2181, startLng: -149.9003, endLat: 61.1743, endLng: -149.9982,
            departure: morning, estimatedTravelTime: 22 * 60,
            scheduledArrival: morning.addingTimeInterval(22 * 60),
            repeatRule: .weekdays, category: .work, paidBy: PayerGroup.parentsKey, vehicleName: "My Subaru")
        let evening = cal.date(bySettingHour: 17, minute: 30, second: 0, of: Date()) ?? Date()
        let s2 = ScheduledDrive(
            title: "Gym", startAddress: "Apex Engineering", endAddress: "The Alaska Club",
            startLat: 61.1743, startLng: -149.9982, endLat: 61.19, endLng: -149.88,
            departure: evening, estimatedTravelTime: 14 * 60,
            scheduledArrival: evening.addingTimeInterval(14 * 60),
            repeatRule: .weekly, category: .leisure, vehicleName: "My Subaru")
        s2.setOccurrenceCanceled(s2.nextDeparture(), true)   // cancel just the next occurrence → CANCELED

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

    /// An in-progress multi-stop drive (Downtown → Midtown stop → Airport). `paused` shows the
    /// between-legs "parked at a stop" state; otherwise it's recording the second leg.
    @MainActor
    static func multiLegTracker(paused: Bool) -> LocationTracker {
        let t = inProgressTracker()
        t.finalDestinationName = "Ted Stevens Intl Airport"
        // stop 1 (reached), stop 2 (upcoming), then the final destination target.
        t.legTargets = [
            RouteStop(address: "Midtown Costco", lat: 61.1900, lng: -149.9000),
            RouteStop(address: "Spenard Post Office", lat: 61.1810, lng: -149.9400),
            RouteStop(address: "Ted Stevens Intl Airport", lat: 61.1743, lng: -149.9982),
        ]
        t.currentLegIndex = 1          // reached stop 1; now on leg 2 (→ stop 2)
        t.legArrivals = [Date().addingTimeInterval(-300)]
        // Boundary at stop 1 so the paused recap can report the just-finished leg's distance/time.
        t.legPointBoundaries = [max(2, t.points.count / 2)]
        t.destination = t.legTargets[1].coordinate
        t.destinationName = t.legTargets[1].address
        t.isPausedBetweenLegs = paused
        return t
    }

    /// A fresh, not-yet-started ad-hoc drive (optionally with a pre-set destination) for verifying
    /// the pre-start controls — the "Set destination" row and the Start button.
    @MainActor
    static func idleTracker(withDestination: Bool) -> LocationTracker {
        let t = LocationTracker()
        t.currentLocation = .init(latitude: 61.2181, longitude: -149.9003)
        if withDestination {
            t.setRoute(stops: [],
                       finalDestination: .init(latitude: 61.1743, longitude: -149.9982),
                       finalName: "Ted Stevens Intl Airport")
        }
        return t
    }

    /// An in-progress OPEN drive (no destination) for verifying the on-the-fly "Set destination" /
    /// "Add stop" control a plain ad-hoc drive now offers mid-drive.
    @MainActor
    static func openDriveTracker() -> LocationTracker {
        let t = inProgressTracker()
        t.destination = nil
        t.destinationName = nil
        t.legTargets = []
        t.scheduledArrival = nil
        return t
    }

    /// A "Go to" drive with a live location + a computed schedule, so the ETA HUD resolves to a real
    /// on-time verdict — verifying that a scheduled/Go-to drive never falls back to "NO SCHEDULE".
    @MainActor
    static func goToStatusTracker() -> LocationTracker {
        let t = inProgressTracker()
        t.finalDestinationName = "Home"
        t.destinationName = "Home"
        t.scheduledArrival = Date().addingTimeInterval(30 * 60)  // ample budget → ON TIME / EARLY
        return t
    }
}

// MARK: - Full sample-data seed for manual testing (UITEST_SEED=1)

extension SampleData {
    /// Comprehensive seed for manually exercising the app in a real (non-headless) simulator run —
    /// triggered by launching with the `UITEST_SEED=1` environment variable (see `ContentView`).
    /// Unlike the screenshot fixtures above (which each seed just enough for one screen), this
    /// populates every model the newer features touch in one pass: two vehicles (one with a fill-up
    /// date, for the pumped-vs-estimated comparison), a custom payer group beyond the built-in
    /// Me/Parents, trips spanning several fill-up windows across all three payers, upcoming scheduled
    /// drives, and saved places. Safe to call every launch — no-ops once the marker vehicle exists.
    @MainActor
    static func seedEverythingForTesting(context: ModelContext) {
        guard (try? context.fetch(FetchDescriptor<Vehicle>()))?.isEmpty ?? true else { return }

        seedPlaces(into: context)
        seedSchedules(into: context)

        let subaru = Vehicle(name: "My Subaru", make: "Subaru", model: "Outback", year: 2021, tankSize: 16.5, avgMpg: 28)
        subaru.lastFilledUp = Date().addingTimeInterval(-3 * 86400)
        let crv = Vehicle(name: "Mom's CR-V", make: "Honda", model: "CR-V", year: 2019, tankSize: 14, avgMpg: 26)
        context.insert(subaru)
        context.insert(crv)

        // A custom payer group beyond the two built-ins, to prove "add a payer group" end-to-end —
        // it should show up in every payer picker, the Stats breakdown, and the Gas filter.
        let grandma = PayerGroup(key: "GROUP_TEST_GRANDMA", name: "Grandma", icon: "figure.wave",
                                 colorName: "purple", sortOrder: 2)
        context.insert(grandma)

        // Trips for "My Subaru" spanning three fill-up windows (20d/10d/3d ago — matching
        // `sampleGasEntries()` below), across all three payers, so the Gas tab's pumped-vs-estimated
        // comparison and the Stats "Who's paying" breakdown both have real, varied data.
        let payers = [PayerGroup.selfKey, PayerGroup.parentsKey, "GROUP_TEST_GRANDMA"]
        let destinations = ["Apex Engineering", "Ted Stevens Intl Airport", "The Alaska Club"]
        let categories: [TripCategory] = [.commute, .errand, .work, .leisure]
        for (i, offset) in [-19, -17, -14, -12, -9, -7, -5, -2, -1].enumerated() {
            insertTestTrip(into: context, daysAgo: offset, vehicleName: "My Subaru", ratedMpg: 28,
                           endAddress: destinations[i % destinations.count],
                           category: categories[i % categories.count], paidBy: payers[i % payers.count])
        }
        // A couple of trips for the second car too, so "Time in each car" / the vehicle picker have
        // more than one real option.
        for offset in [-6, -2] {
            insertTestTrip(into: context, daysAgo: offset, vehicleName: "Mom's CR-V", ratedMpg: 26,
                           endAddress: "The Alaska Club", category: .leisure, paidBy: PayerGroup.parentsKey)
        }

        try? context.save()
    }

    private static func insertTestTrip(into context: ModelContext, daysAgo: Int, vehicleName: String,
                                        ratedMpg: Double, endAddress: String, category: TripCategory, paidBy: String) {
        let base = Date().addingTimeInterval(Double(daysAgo) * 86400)
        let pts = recordedPoints(base: base)
        guard let first = pts.first, let last = pts.last else { return }
        var meters = 0.0
        for k in 1..<pts.count { meters += pts[k - 1].coordinate.distanceMeters(to: pts[k].coordinate) }
        let miles = meters / 1609.34
        let secs = Int(last.t.timeIntervalSince(first.t))
        let gallons = FuelModel.gallons(segments: FuelModel.segments(from: pts), ratedMpg: ratedMpg)
        let trip = DriveTrip(
            date: first.t, endDate: last.t,
            startAddress: "Home", endAddress: endAddress,
            startLat: first.lat, startLng: first.lng, endLat: last.lat, endLng: last.lng,
            distance: miles, duration: secs, movingSeconds: Int(Double(secs) * 0.85),
            maxSpeed: pts.map(\.speed).max() ?? 0, avgSpeed: secs > 0 ? miles / (Double(secs) / 3600) : 0,
            category: category, paidBy: paidBy,
            vehicleName: vehicleName, vehicleMpg: ratedMpg, estimatedGallons: gallons)
        context.insert(trip)
        for (k, p) in pts.enumerated() {
            let tp = TrackPoint(seq: k, t: p.t, lat: p.lat, lng: p.lng, speed: p.speed,
                                course: p.course, accuracy: p.accuracy, altitude: p.altitude, onRoad: true)
            tp.trip = trip
            context.insert(tp)
        }
    }

    /// Fake gas fill-ups for "My Subaru" spanning the same three windows as the seeded trips above.
    /// Used only as a local stand-in when the real backend is unreachable (see
    /// `GasListView.loadEntries`) so the pumped-vs-estimated comparison can be checked in a manual
    /// test run without a live backend connection or real account data.
    static func sampleGasEntries() -> [APIGasEntry] {
        let f = ISO8601DateFormatter()
        func iso(_ daysAgo: Int) -> String { f.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86400)) }
        return [
            APIGasEntry(id: "test-1", date: iso(20), gallons: 11.4, pricePerGallon: 3.79,
                       totalCost: 11.4 * 3.79, paidBy: PayerGroup.selfKey, fuelType: "REGULAR",
                       stationName: "Costco", odometer: 30500, vehicleName: "My Subaru"),
            APIGasEntry(id: "test-2", date: iso(10), gallons: 2.1, pricePerGallon: 3.85,
                       totalCost: 2.1 * 3.85, paidBy: PayerGroup.parentsKey, fuelType: "REGULAR",
                       stationName: "Tesoro", odometer: 30700, vehicleName: "My Subaru"),
            APIGasEntry(id: "test-3", date: iso(3), gallons: 10.8, pricePerGallon: 3.72,
                       totalCost: 10.8 * 3.72, paidBy: "GROUP_TEST_GRANDMA", fuelType: "PREMIUM",
                       stationName: "Costco", odometer: 30950, vehicleName: "My Subaru"),
            APIGasEntry(id: "test-4", date: iso(6), gallons: 9.6, pricePerGallon: 3.65,
                       totalCost: 9.6 * 3.65, paidBy: PayerGroup.parentsKey, fuelType: "REGULAR",
                       stationName: "Fred Meyer", odometer: 15200, vehicleName: "Mom's CR-V"),
        ]
    }
}
#endif
