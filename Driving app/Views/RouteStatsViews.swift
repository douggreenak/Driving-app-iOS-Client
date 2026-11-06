import SwiftUI
import SwiftData
import Charts

// MARK: - Stats cards

/// "Top Routes" — the most-driven from→to pairs, tappable into the route explorer.
struct TopRoutesCard: View {
    let trips: [DriveTrip]
    let places: [SavedPlace]

    var body: some View {
        let routes = RouteStats.summaries(trips: trips, places: places).filter { $0.count >= 2 }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Top Routes", systemImage: "arrow.triangle.swap").font(.headline)
                Spacer()
                NavigationLink { RouteExplorerView(trips: trips, places: places) } label: {
                    Text("Explore").font(.subheadline.weight(.semibold))
                }
            }
            if routes.isEmpty {
                Text("Routes you drive more than once will show up here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(routes.prefix(5)) { r in
                NavigationLink { RouteDetailView(route: r) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.from) → \(r.to)").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(r.count) trips · avg \(Fmt.duration(r.avgSeconds))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if r.id != routes.prefix(5).last?.id { Divider() }
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }
}

/// "Patterns" — when you drive and where you go most, from existing trips only.
struct PatternsCard: View {
    let trips: [DriveTrip]
    let places: [SavedPlace]

    private struct Day: Identifiable { var id: Int; var label: String; var count: Int }

    var body: some View {
        let cal = Calendar.current
        let counts = Dictionary(grouping: trips, by: { cal.component(.weekday, from: $0.date) }).mapValues(\.count)
        let symbols = cal.shortWeekdaySymbols
        let days = (1...7).map { Day(id: $0, label: symbols[$0 - 1], count: counts[$0] ?? 0) }
        let dests = Dictionary(grouping: trips, by: { RouteStats.name($0.endCoordinate, $0.endAddress, places: places) })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(5)

        VStack(alignment: .leading, spacing: 14) {
            Label("Patterns", systemImage: "calendar.badge.clock").font(.headline)
            Chart(days) { d in
                BarMark(x: .value("Day", d.label), y: .value("Trips", d.count))
                    .foregroundStyle(d.count == (days.map(\.count).max() ?? 0) ? Color.blue : Color.blue.opacity(0.45))
                    .cornerRadius(4)
            }
            .frame(height: 110)
            .chartYAxis(.hidden)
            if let busiest = days.max(by: { $0.count < $1.count }), busiest.count > 0 {
                Text("You drive most on \(cal.weekdaySymbols[busiest.id - 1])s (\(busiest.count) trips).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Most-visited places").font(.subheadline.weight(.semibold))
            ForEach(Array(dests), id: \.0) { name, n in
                HStack { Text(name).lineLimit(1); Spacer(); Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
                    .font(.subheadline)
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }
}

// MARK: - Route explorer

/// Pick a start and a destination (only places that actually exist in your trips) and see every trip
/// between them with average / fastest / slowest times, like Flighty's route pages.
struct RouteExplorerView: View {
    let trips: [DriveTrip]
    let places: [SavedPlace]
    @State private var from: String?
    @State private var to: String?

    private var all: [RouteSummary] { RouteStats.summaries(trips: trips, places: places) }
    private var starts: [String] { Array(Set(all.map(\.from))).sorted() }
    private var ends: [String] {
        Array(Set(all.filter { from == nil || $0.from == from }.map(\.to))).sorted()
    }
    private var matches: [RouteSummary] {
        all.filter { (from == nil || $0.from == from) && (to == nil || $0.to == to) }
    }

    var body: some View {
        List {
            Section {
                Picker("From", selection: $from) {
                    Text("Anywhere").tag(String?.none)
                    ForEach(starts, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("To", selection: $to) {
                    Text("Anywhere").tag(String?.none)
                    ForEach(ends, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            } footer: { Text("\(matches.count) route\(matches.count == 1 ? "" : "s") · \(matches.reduce(0) { $0 + $1.count }) trips") }

            Section("Routes") {
                ForEach(matches) { r in
                    NavigationLink { RouteDetailView(route: r) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(r.from) → \(r.to)").font(.subheadline.weight(.semibold))
                            Text("\(r.count) trips · avg \(Fmt.duration(r.avgSeconds)) · \(String(format: "%.1f mi", r.avgMiles))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Routes")
        .onChange(of: from) { _, _ in if let t = to, !ends.contains(t) { to = nil } }
    }
}

/// Everything about one from→to route.
struct RouteDetailView: View {
    let route: RouteSummary

    private struct Point: Identifiable { let id: Int; let date: Date; let minutes: Double }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("\(route.from) → \(route.to)").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    Text("\(route.count) trips" + (route.lastDriven.map { " · last \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 10) {
                    tile("Average", Fmt.duration(route.avgSeconds), .blue)
                    tile("Fastest", route.fastest.map { Fmt.duration($0.duration) } ?? "—", .green)
                    tile("Slowest", route.slowest.map { Fmt.duration($0.duration) } ?? "—", .orange)
                    tile("Avg distance", String(format: "%.1f mi", route.avgMiles), .teal)
                    tile("Shortest", String(format: "%.1f mi", route.minMiles), .mint)
                    tile("Longest", String(format: "%.1f mi", route.maxMiles), .indigo)
                    tile("Avg speed", String(format: "%.0f mph", route.avgMph), .purple)
                    tile("Total", String(format: "%.0f mi", route.totalMiles), .pink)
                    tile("Gas (est.)", String(format: "%.1f gal", route.totalGallons), .yellow)
                }
                if let best = route.bestDepartureHour {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.badge.checkmark.fill").foregroundStyle(.green)
                        Text("Fastest around \(hourLabel(best.hour)) — averaging \(Fmt.duration(best.avgSeconds)).")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding().background(Color(.systemGray6), in: .rect(cornerRadius: 14))
                }
                if let pct = route.onTimePercent {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                        Text(String(format: "On time %.0f%% of the time on this route.", pct)).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding().background(Color(.systemGray6), in: .rect(cornerRadius: 14))
                }
                chart
                VStack(alignment: .leading, spacing: 0) {
                    Text("All trips").font(.headline).padding(.bottom, 8)
                    ForEach(route.trips) { t in
                        NavigationLink { TripDetailView(trip: t) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                                    Text(String(format: "%.1f mi · %@", t.distance, Fmt.duration(t.duration)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if t.persistentModelID == route.fastest?.persistentModelID {
                                    Label("Fastest", systemImage: "bolt.fill").font(.caption2).foregroundStyle(.green)
                                } else if t.persistentModelID == route.slowest?.persistentModelID {
                                    Label("Slowest", systemImage: "tortoise.fill").font(.caption2).foregroundStyle(.orange)
                                }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
            }
            .padding()
        }
        .background(.black)
        .navigationTitle("Route")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var chart: some View {
        let pts = route.trips.filter { $0.duration > 0 }.sorted { $0.date < $1.date }
            .enumerated().map { Point(id: $0.offset, date: $0.element.date, minutes: Double($0.element.duration) / 60) }
        if pts.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Time over the trips").font(.headline)
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Minutes", p.minutes)).foregroundStyle(.blue)
                        PointMark(x: .value("Date", p.date), y: .value("Minutes", p.minutes)).foregroundStyle(.blue)
                    }
                    RuleMark(y: .value("Average", Double(route.avgSeconds) / 60))
                        .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("avg").font(.caption2).foregroundStyle(.orange)
                        }
                }
                .frame(height: 150)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
        }
    }

    private func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now) ?? .now
        return d.formatted(.dateTime.hour())
    }

    private func tile(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline).fontDesign(.rounded).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }
}
