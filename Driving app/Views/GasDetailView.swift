import SwiftUI
import SwiftData

/// A past fill-up in full — modelled on the trip detail page: headline cost, who paid, which car,
/// and how the pumped gallons compare with what the app's fuel model says the trips burned.
struct GasDetailView: View {
    let entry: APIGasEntry
    let payer: PayerDisplay
    let comparison: FuelComparison?
    /// Every fill-up (to find this car's previous one) and all trips (to total what was driven since).
    let allEntries: [APIGasEntry]
    let trips: [DriveTrip]

    private var previous: APIGasEntry? {
        guard let car = entry.vehicleName else { return nil }
        return allEntries.filter { $0.vehicleName == car && $0.parsedDate < entry.parsedDate }
            .max { $0.parsedDate < $1.parsedDate }
    }

    /// Trips in this car between the previous fill-up and this one.
    private var tripsSince: [DriveTrip] {
        guard let car = entry.vehicleName else { return [] }
        let from = previous?.parsedDate
        return trips.filter { $0.vehicleName == car && $0.date <= entry.parsedDate && (from == nil || $0.date > from!) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(entry.totalCost, format: .currency(code: "USD"))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                    Text(entry.parsedDate.formatted(date: .complete, time: .shortened))
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: payer.icon)
                        Text("Paid by \(payer.name)")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(payer.color)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(payer.color.opacity(0.18), in: .capsule)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)

                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                    box("fuelpump.fill", .orange, String(format: "%.2f gal", entry.gallons), "Pumped")
                    box("dollarsign.circle.fill", .green, String(format: "$%.3f", entry.pricePerGallon), "Per gallon")
                    box("drop.fill", .blue, entry.fuelTypeEnum.shortLabel, "Fuel type")
                    box("car.fill", .purple, entry.vehicleName ?? "—", "Car")
                }

                if entry.stationName != nil || entry.odometer != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let station = entry.stationName, !station.isEmpty {
                            line("building.2.fill", "Station", station)
                        }
                        if let odo = entry.odometer {
                            line("gauge.with.dots.needle.67percent", "Odometer", String(format: "%.0f mi", odo))
                        }
                    }
                    .card()
                }

                sinceCard
                if let comparison {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Pumped vs. estimated", systemImage: "scalemass.fill").font(.headline)
                        Text(comparison.summary).font(.subheadline)
                            .foregroundStyle(comparison.isCloseMatch ? Color.secondary : Color.statusDelay)
                        if !comparison.isCloseMatch {
                            Text("A big gap usually means a missed trip or a partial fill-up.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .card()
                }
            }
            .padding()
        }
        .background(.black)
        .navigationTitle("Fill-up")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var sinceCard: some View {
        let miles = tripsSince.reduce(0) { $0 + $1.distance }
        VStack(alignment: .leading, spacing: 10) {
            Label(previous == nil ? "Driven before this fill-up" : "Since the previous fill-up",
                  systemImage: "road.lanes").font(.headline)
            if let p = previous {
                line("calendar", "Previous fill-up", p.parsedDate.formatted(date: .abbreviated, time: .omitted))
            }
            line("map.fill", "Trips", "\(tripsSince.count)")
            line("point.topleft.down.to.point.bottomright.curvepath.fill", "Distance", String(format: "%.1f mi", miles))
            if miles > 5, entry.gallons > 0 {
                line("speedometer", "Actual MPG", String(format: "%.1f", miles / entry.gallons))
            }
            if let p = previous, let a = entry.odometer, let b = p.odometer, a > b, entry.gallons > 0 {
                line("gauge.with.dots.needle.67percent", "Odometer MPG", String(format: "%.1f", (a - b) / entry.gallons))
            }
        }
        .card()
    }

    private func box(_ icon: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.title3.weight(.bold)).fontDesign(.rounded).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 14))
    }

    private func line(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

private extension View {
    func card() -> some View {
        self.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }
}
