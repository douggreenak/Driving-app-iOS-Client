import SwiftUI

struct GasListView: View {
    @State private var entries: [APIGasEntry] = []
    @State private var loading = true
    @State private var showingNewEntry = false
    @State private var filter: PaidByFilter = .all

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

                HStack {
                    VStack {
                        Text(filteredTotal, format: .currency(code: "USD"))
                            .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                        Text("total").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack {
                        Text(String(format: "%.1f gal", filteredGallons))
                            .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                        Text("used").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal).padding(.bottom, 8)

                if loading {
                    ProgressView().padding(.top, 40)
                    Spacer()
                } else if filteredEntries.isEmpty {
                    ContentUnavailableView("No Gas Entries", systemImage: "fuelpump", description: Text("Track your fuel expenses"))
                } else {
                    List {
                        ForEach(filteredEntries) { entry in
                            GasRow(entry: entry)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { deleteEntry(entry) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .background(.black)
            .navigationTitle("Gas Log")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewEntry = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingNewEntry) {
                NewGasEntryView { await loadEntries() }
            }
            .refreshable { await loadEntries() }
            .task { await loadEntries() }
        }
    }

    private func loadEntries() async {
        do {
            entries = try await APIClient.fetchGasEntries()
            loading = false
        } catch { loading = false }
    }

    private func deleteEntry(_ entry: APIGasEntry) {
        Task {
            try? await APIClient.deleteGasEntry(id: entry.id)
            entries.removeAll { $0.id == entry.id }
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
