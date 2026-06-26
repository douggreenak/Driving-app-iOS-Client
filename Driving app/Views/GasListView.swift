import SwiftUI
import SwiftData

struct GasListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GasEntry.date, order: .reverse) private var entries: [GasEntry]
    @State private var showingNewEntry = false
    @State private var filter: PaidByFilter = .all

    enum PaidByFilter: CaseIterable {
        case all, myself, parents
        var label: String {
            switch self {
            case .all: "All"
            case .myself: "Me"
            case .parents: "Parents"
            }
        }
    }

    private var filteredEntries: [GasEntry] {
        switch filter {
        case .all: entries
        case .myself: entries.filter { $0.paidBy == .myself }
        case .parents: entries.filter { $0.paidBy == .parents }
        }
    }

    private var filteredTotal: Double { filteredEntries.reduce(0) { $0 + $1.totalCost } }
    private var filteredGallons: Double { filteredEntries.reduce(0) { $0 + $1.gallons } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(PaidByFilter.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                HStack {
                    VStack {
                        Text(filteredTotal, format: .currency(code: "USD"))
                            .font(.title2)
                            .fontWeight(.bold)
                            .fontDesign(.rounded)
                            .contentTransition(.numericText())
                        Text("total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack {
                        Text(String(format: "%.1f gal", filteredGallons))
                            .font(.title2)
                            .fontWeight(.bold)
                            .fontDesign(.rounded)
                        Text("used")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "No Gas Entries",
                        systemImage: "fuelpump",
                        description: Text("Track your fuel expenses")
                    )
                } else {
                    List {
                        ForEach(filteredEntries) { entry in
                            GasRow(entry: entry)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Gas Log")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewEntry = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewEntry) {
                NewGasEntryView()
            }
        }
    }
}

private struct GasRow: View {
    let entry: GasEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.paidBy.label)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            entry.paidBy == .myself ? Color.blue.opacity(0.15) : Color.green.opacity(0.15),
                            in: .capsule
                        )
                    Text(entry.fuelType.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%.1f gal @ $%.2f/gal", entry.gallons, entry.pricePerGallon))
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let station = entry.stationName, !station.isEmpty {
                    Text(station)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let odo = entry.odometer {
                    Text(String(format: "Odometer: %.0f mi", odo))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(entry.totalCost, format: .currency(code: "USD"))
                .font(.headline)
                .fontDesign(.rounded)
        }
        .padding(.vertical, 4)
    }
}
