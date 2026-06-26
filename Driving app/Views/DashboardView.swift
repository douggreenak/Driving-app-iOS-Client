import SwiftUI

struct DashboardView: View {
    @State private var stats: APIStats?
    @State private var recentTrip: APITrip?
    @State private var loading = true

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView()
                        .padding(.top, 80)
                } else if let stats {
                    VStack(spacing: 20) {
                        statsGrid(stats)
                        miniStats(stats)
                        spendingSection(stats)
                        if let trip = recentTrip {
                            recentTripSection(trip)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .background(.black)
            .navigationTitle(greeting)
            .refreshable { await loadData() }
            .task { await loadData() }
        }
    }

    private func loadData() async {
        do {
            async let s = APIClient.fetchStats()
            async let t = APIClient.fetchTrips()
            let (fetchedStats, trips) = try await (s, t)
            stats = fetchedStats
            recentTrip = trips.first
            loading = false
        } catch {
            loading = false
        }
    }

    private func statsGrid(_ s: APIStats) -> some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            StatTile(icon: "car.fill", label: "Trips", value: "\(s.totalTrips)", sublabel: "\(s.weeklyTrips) this week", tint: .blue)
            StatTile(icon: "arrow.triangle.swap", label: "Miles", value: String(format: "%.1f", s.totalMiles), sublabel: String(format: "%.1f this week", s.weeklyMiles), tint: .green)
            StatTile(icon: "drop.fill", label: "Gallons", value: String(format: "%.1f", s.totalGallons), sublabel: String(format: "%.1f avg MPG", s.avgMpg), tint: .orange)
            StatTile(icon: "dollarsign", label: "Spent", value: String(format: "$%.2f", s.totalSpent), sublabel: String(format: "$%.2f/mi", s.costPerMile), tint: .purple)
        }
    }

    private func miniStats(_ s: APIStats) -> some View {
        HStack(spacing: 12) {
            MiniTile(label: "This Month", value: String(format: "$%.2f", s.monthlySpent))
            MiniTile(label: "Favorites", value: "\(s.favoriteCount)")
        }
    }

    private func spendingSection(_ s: APIStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gas Spending")
                .font(.headline)
            Text(s.totalSpent, format: .currency(code: "USD"))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))

            if s.totalSpent > 0 {
                VStack(spacing: 10) {
                    BarRow(label: "Paid by Me", amount: s.selfPaid, total: s.totalSpent, color: .blue)
                    BarRow(label: "Paid by Parents", amount: s.parentsPaid, total: s.totalSpent, color: .green)
                }
            } else {
                Text("No spending yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }

            if s.monthlyBudget > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Monthly Budget").font(.subheadline)
                        Spacer()
                        Text(String(format: "$%.2f / $%.2f", s.monthlySpent, s.monthlyBudget))
                            .font(.subheadline.weight(.semibold))
                    }
                    let pct = min(s.monthlySpent / s.monthlyBudget, 1)
                    ProgressView(value: pct)
                        .tint(pct > 0.9 ? .red : pct > 0.7 ? .orange : .green)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }

    private func recentTripSection(_ trip: APITrip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latest Trip").font(.headline)
                Spacer()
                Label(trip.tripCategory.label, systemImage: trip.tripCategory.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.startAddress).font(.subheadline.weight(.medium))
                    Label(trip.endAddress, systemImage: "arrow.right")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.1f mi", trip.distance))
                        .font(.subheadline.weight(.semibold))
                    Text(trip.parsedDate, style: .date)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }
}

private struct StatTile: View {
    let icon: String; let label: String; let value: String
    var sublabel: String? = nil; let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title3.weight(.medium)).foregroundStyle(tint)
            Text(value).font(.system(.title, design: .rounded, weight: .bold))
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            if let sublabel { Text(sublabel).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }
}

private struct MiniTile: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
    }
}

private struct BarRow: View {
    let label: String; let amount: Double; let total: Double; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(amount, format: .currency(code: "USD")).font(.subheadline.weight(.semibold))
            }
            ProgressView(value: total > 0 ? amount / total : 0).tint(color)
        }
    }
}
