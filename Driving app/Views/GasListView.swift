import SwiftUI

struct GasListView: View {
    @State private var entries: [APIGasEntry] = []
    @State private var loading = true
    @State private var isRefreshing = false
    @State private var lastUpdated: Date?
    @State private var showingNewEntry = false
    @State private var filter: PaidByFilter = .all
    @State private var pendingDelete: APIGasEntry?

    enum PaidByFilter: CaseIterable {
        case all, myself, parents
        var label: String {
            switch self { case .all: "All"; case .myself: "Me"; case .parents: "Parents" }
        }
    }

    private var filteredEntries: [APIGasEntry] {
        switch filter {
        case .all: entries
        case .myself: entries.filter { $0.paidBy == "SELF" }
        case .parents: entries.filter { $0.paidBy == "PARENTS" }
        }
    }

    private var filteredTotal: Double { filteredEntries.reduce(0) { $0 + $1.totalCost } }
    private var filteredGallons: Double { filteredEntries.reduce(0) { $0 + $1.gallons } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(PaidByFilter.allCases, id: \.self) { Text($0.label).tag($0) }
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
                        Text(filter == .all ? "Log a fill-up to track fuel spending and who paid."
                                            : "No fill-ups paid by \(filter.label).")
                    } actions: {
                        if filter == .all {
                            Button { Haptics.tap(); showingNewEntry = true } label: {
                                Label("Add Fill-up", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    List {
                        ForEach(filteredEntries) { entry in
                            GasRow(entry: entry)
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
            .task { await loadEntries() }
        }
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
        } catch { loading = false }
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

private struct GasRow: View {
    let entry: APIGasEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.paidByEnum.label)
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(entry.paidBy == "SELF" ? Color.blue.opacity(0.15) : Color.green.opacity(0.15), in: .capsule)
                    Text(entry.parsedDate, style: .date)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: "%.1f gal @ $%.2f/gal", entry.gallons, entry.pricePerGallon))
                    .font(.subheadline).fontWeight(.medium)
                if let station = entry.stationName, !station.isEmpty {
                    Text(station).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.totalCost, format: .currency(code: "USD"))
                .font(.headline).fontDesign(.rounded)
        }
        .padding(.vertical, 4)
    }
}
