import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query private var trips: [Trip]
    @Query private var gasEntries: [GasEntry]
    @Query private var settings: [UserSettings]

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private var totalMiles: Double { trips.reduce(0) { $0 + $1.distance } }
    private var totalGallons: Double { gasEntries.reduce(0) { $0 + $1.gallons } }
    private var totalSpent: Double { gasEntries.reduce(0) { $0 + $1.totalCost } }
    private var selfPaid: Double { gasEntries.filter { $0.paidBy == .myself }.reduce(0) { $0 + $1.totalCost } }
    private var parentsPaid: Double { gasEntries.filter { $0.paidBy == .parents }.reduce(0) { $0 + $1.totalCost } }
    private var avgMpg: Double { totalGallons > 0 ? totalMiles / totalGallons : 0 }
    private var costPerMile: Double { totalMiles > 0 ? totalSpent / totalMiles : 0 }

    private var monthlySpent: Double {
        let now = Date.now
        let cal = Calendar.current
        return gasEntries
            .filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.totalCost }
    }

    private var weeklyTrips: [Trip] {
        let weekAgo = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        return trips.filter { $0.date > weekAgo }
    }

    private var budget: Double { settings.first?.monthlyBudget ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statsGrid
                    miniStats
                    spendingSection
                    if let recentTrip = trips.sorted(by: { $0.date > $1.date }).first {
                        recentTripSection(recentTrip)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .background(.black)
            .navigationTitle(greeting)
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            StatTile(icon: "car.fill", label: "Trips", value: "\(trips.count)", sublabel: "\(weeklyTrips.count) this week", tint: .blue)
            StatTile(icon: "arrow.triangle.swap", label: "Miles", value: String(format: "%.1f", totalMiles), sublabel: String(format: "%.1f this week", weeklyTrips.reduce(0) { $0 + $1.distance }), tint: .green)
            StatTile(icon: "drop.fill", label: "Gallons", value: String(format: "%.1f", totalGallons), sublabel: String(format: "%.1f avg MPG", avgMpg), tint: .orange)
            StatTile(icon: "dollarsign", label: "Spent", value: totalSpent.formatted(.currency(code: "USD")), sublabel: String(format: "$%.2f/mi", costPerMile), tint: .purple)
        }
    }

    private var miniStats: some View {
        HStack(spacing: 12) {
            MiniTile(label: "This Month", value: monthlySpent.formatted(.currency(code: "USD")))
            MiniTile(label: "Favorites", value: "\(trips.filter(\.isFavorite).count)")
        }
    }

    private var spendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gas Spending")
                .font(.headline)

            Text(totalSpent, format: .currency(code: "USD"))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .contentTransition(.numericText())

            if totalSpent > 0 {
                VStack(spacing: 10) {
                    BarRow(label: "Paid by Me", amount: selfPaid, total: totalSpent, color: .blue)
                    BarRow(label: "Paid by Parents", amount: parentsPaid, total: totalSpent, color: .green)
                }
            } else {
                Text("No spending yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }

            if budget > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Monthly Budget")
                            .font(.subheadline)
                        Spacer()
                        Text("\(monthlySpent.formatted(.currency(code: "USD"))) / \(budget.formatted(.currency(code: "USD")))")
                            .font(.subheadline.weight(.semibold))
                    }
                    let pct = min(monthlySpent / budget, 1)
                    ProgressView(value: pct)
                        .tint(pct > 0.9 ? .red : pct > 0.7 ? .orange : .green)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    private func recentTripSection(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latest Trip")
                    .font(.headline)
                Spacer()
                Label(trip.category.label, systemImage: trip.category.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.startAddress)
                        .font(.subheadline.weight(.medium))
                    Label(trip.endAddress, systemImage: "arrow.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.1f mi", trip.distance))
                        .font(.subheadline.weight(.semibold))
                    Text(trip.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Components

private struct StatTile: View {
    let icon: String
    let label: String
    let value: String
    var sublabel: String? = nil
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let sublabel {
                Text(sublabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }
}

private struct MiniTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }
}

private struct BarRow: View {
    let label: String
    let amount: Double
    let total: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(amount, format: .currency(code: "USD"))
                    .font(.subheadline.weight(.semibold))
            }
            ProgressView(value: total > 0 ? amount / total : 0)
                .tint(color)
        }
    }
}
