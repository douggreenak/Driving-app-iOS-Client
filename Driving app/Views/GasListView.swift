import SwiftUI
import SwiftData

struct GasListView: View {
    @State private var entries: [APIGasEntry] = []
    @State private var loading = true
    @State private var isRefreshing = false
    @State private var lastUpdated: Date?
    @State private var showingNewEntry = false
    /// nil = "All"; otherwise a `PayerGroup.key` to filter to.
    @State private var filterKey: String?
    @State private var pendingDelete: APIGasEntry?
    @Query(sort: \PayerGroup.sortOrder) private var payerGroups: [PayerGroup]
    @Query(sort: \DriveTrip.date) private var trips: [DriveTrip]
    @Environment(\.tabActivityToken) private var activityToken

    private var filteredEntries: [APIGasEntry] {
        guard let filterKey else { return entries }
        return entries.filter { $0.paidBy == filterKey }
    }

    private var filterLabel: String {
        guard let filterKey else { return "All" }
        return PayerGroup.resolve(key: filterKey, in: payerGroups).name
    }

    private var filteredTotal: Double { filteredEntries.reduce(0) { $0 + $1.totalCost } }
    private var filteredGallons: Double { filteredEntries.reduce(0) { $0 + $1.gallons } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filterKey) {
                    Text("All").tag(String?.none)
                    ForEach(payerGroups.filter { !$0.isArchived }) { group in
                        Text(group.name).tag(String?.some(group.key))
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                .disabled(loading)

                // Only show the totals row once there's something to total.
                if !filteredEntries.isEmpty {
                    HStack {
                        VStack {
                            Text(filteredTotal, format: .currency(code: "USD"))
                                .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                                .contentTransition(.numericText())
                            Text(filteredEntries.count.things("fill-up")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack {
                            Text(String(format: "%.1f gal", filteredGallons))
                                .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                                .contentTransition(.numericText())
                            Text("used").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal).padding(.bottom, 8)
                }

                LastUpdatedBanner(lastUpdated: lastUpdated, isRefreshing: isRefreshing)

                if loading {
                    ProgressView().padding(.top, 40)
                    Spacer()
                } else if filteredEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No Gas Entries", systemImage: "fuelpump")
                    } description: {
                        Text(filterKey == nil ? "Log a fill-up to track fuel spending and who paid."
                                              : "No fill-ups paid by \(filterLabel).")
                    } actions: {
                        if filterKey == nil {
                            Button { Haptics.tap(); showingNewEntry = true } label: {
                                Label("Add Fill-up", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    List {
                        ForEach(filteredEntries) { entry in
                            GasRow(entry: entry, payer: entry.payer(in: payerGroups),
                                  comparison: fuelComparison(for: entry))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = entry } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .background(.black)
            .navigationTitle("Gas Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewEntry = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingNewEntry) {
                NewGasEntryView { await loadEntries() }
            }
            .confirmationDialog("Delete this fill-up?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Fill-up", role: .destructive) {
                    if let e = pendingDelete { deleteEntry(e) }
                    pendingDelete = nil
                }
            }
            .refreshable { await loadEntries() }
            // `.task(id:)` (rather than a bare `.task`) so this refetches every time the Gas tab is
            // revisited or the app returns to the foreground, not just the first time this view is
            // created — otherwise switching tabs and back could show stale entries until a relaunch.
            .task(id: activityToken) { await loadEntries() }
        }
    }

    /// Compares what this fill-up actually pumped against what the app's speed-aware fuel model
    /// estimates the vehicle's recorded trips burned since its previous fill-up (or across all
    /// history, if this is the first one on record for that vehicle).
    private func fuelComparison(for entry: APIGasEntry) -> FuelComparison? {
        guard let vehicleName = entry.vehicleName else { return nil }
        let since = entries
            .filter { $0.vehicleName == vehicleName && $0.id != entry.id && $0.parsedDate < entry.parsedDate }
            .map(\.parsedDate)
            .max()
        let estimated = FuelModel.estimatedGallonsBurned(
            vehicleName: vehicleName, since: since, through: entry.parsedDate, trips: trips)
        guard estimated > 0.01 else { return nil }
        return FuelComparison(pumped: entry.gallons, estimated: estimated)
    }

    private func loadEntries() async {
        // Show cached entries instantly, then refresh in the background.
        if entries.isEmpty, let cached = Self.cached() {
            entries = cached.entries
            lastUpdated = cached.date
            loading = false
        }
        isRefreshing = true
        do {
            let fresh = try await APIClient.fetchGasEntries()
            entries = fresh
            lastUpdated = .now
            loading = false
            Self.cache(fresh, at: .now)
        } catch {
            loading = false
            #if DEBUG
            // Manual-testing fallback: with no reachable backend, fall back to a local fixture so the
            // pumped-vs-estimated comparison can still be checked. Only when explicitly launched with
            // `UITEST_SEED=1`, and only if a real fetch never populated `entries` some other way.
            if entries.isEmpty, ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" {
                entries = SampleData.sampleGasEntries()
                lastUpdated = .now
            }
            #endif
        }
        isRefreshing = false
    }

    private static let cacheKey = "gas.cachedEntries"
    private static let dateKey = "gas.cachedEntriesDate"

    private static func cached() -> (entries: [APIGasEntry], date: Date)? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([APIGasEntry].self, from: data) else { return nil }
        let date = UserDefaults.standard.object(forKey: dateKey) as? Date ?? .now
        return (entries, date)
    }

    private static func cache(_ entries: [APIGasEntry], at date: Date) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(date, forKey: dateKey)
        }
    }

    private func deleteEntry(_ entry: APIGasEntry) {
        Haptics.warning()
        Task {
            // Only drop it locally if the server actually deleted it — otherwise a failed delete
            // would vanish from the UI and reappear on the next refresh.
            do {
                try await APIClient.deleteGasEntry(id: entry.id)
                entries.removeAll { $0.id == entry.id }
            } catch {
                // Leave the entry in place; the cache/refresh keeps it consistent with the server.
            }
        }
    }
}

/// Actual gallons pumped at a fill-up vs. what the speed-aware fuel model estimates the vehicle's
/// trips burned since the previous one — a sanity check on the estimate (a big gap usually means an
/// untracked trip, a partial fill-up, or an odometer/tank quirk).
struct FuelComparison {
    var pumped: Double
    var estimated: Double

    private var delta: Double { pumped - estimated }
    private var percentOff: Double { estimated > 0.01 ? delta / estimated * 100 : 0 }

    /// A wide gap (>15%) usually means a missed trip or a partial fill-up rather than model error.
    var isCloseMatch: Bool { abs(percentOff) <= 15 }

    var summary: String {
        String(format: "Pumped %.1f gal · Trips est. %.1f gal (%@%.0f%%)",
              pumped, estimated, delta >= 0 ? "+" : "−", abs(percentOff))
    }
}

private struct GasRow: View {
    let entry: APIGasEntry
    let payer: PayerDisplay
    let comparison: FuelComparison?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(payer.name)
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(payer.color.opacity(0.2), in: .capsule)
                    Text(entry.parsedDate, style: .date)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: "%.1f gal @ $%.2f/gal", entry.gallons, entry.pricePerGallon))
                    .font(.subheadline).fontWeight(.medium)
                // Show car and/or station when present (e.g. "Subaru · Costco").
                let subtitle = [entry.vehicleName, entry.stationName]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let comparison {
                    Text(comparison.summary)
                        .font(.caption2)
                        .foregroundStyle(comparison.isCloseMatch ? Color.secondary : Color.statusDelay)
                }
            }
            Spacer()
            Text(entry.totalCost, format: .currency(code: "USD"))
                .font(.headline).fontDesign(.rounded)
        }
        .padding(.vertical, 4)
    }
}
