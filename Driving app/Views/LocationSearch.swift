import SwiftUI
import SwiftData
import MapKit

/// A concrete picked place: a display address plus its resolved coordinate.
struct PickedLocation {
    var address: String
    var coordinate: CLLocationCoordinate2D
}

/// Live address autocomplete backed by MapKit's `MKLocalSearchCompleter`.
@Observable
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    var results: [MKLocalSearchCompletion] = []

    var query: String = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                results = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    /// Resolve an autocomplete suggestion into a concrete coordinate + address string.
    func resolve(_ completion: MKLocalSearchCompletion) async -> PickedLocation? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        let address = [completion.title, completion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return PickedLocation(address: address, coordinate: item.placemark.coordinate)
    }
}

/// A tappable form row that opens the address search sheet and fills in the picked address.
struct AddressPickerRow: View {
    let title: String
    let systemImage: String
    @Binding var address: String
    @Binding var coordinate: CLLocationCoordinate2D?
    var onPicked: (() -> Void)? = nil

    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(.blue).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(address.isEmpty ? "Search address…" : address)
                        .foregroundStyle(address.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            LocationSearchSheet(title: title) { picked in
                address = picked.address
                coordinate = picked.coordinate
                onPicked?()
            }
        }
    }
}

/// Search sheet: type to see live address suggestions, or tap a saved bookmark.
struct LocationSearchSheet: View {
    let title: String
    var initialQuery: String = ""
    var onPick: (PickedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.sortOrder) private var places: [SavedPlace]
    @State private var completer = AddressCompleter()
    @State private var query = ""
    @State private var resolving = false
    @FocusState private var focused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                List {
                    if isSearching {
                        resultsSection
                    } else {
                        savedSection
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay {
                if resolving { ProgressView().controlSize(.large) }
            }
            .onAppear {
                if !initialQuery.isEmpty { query = initialQuery; completer.query = initialQuery }
                focused = true
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Start typing an address…", text: $query)
                .focused($focused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: query) { _, v in completer.query = v }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.systemGray6), in: .capsule)
        .padding()
    }

    @ViewBuilder
    private var savedSection: some View {
        if places.isEmpty {
            ContentUnavailableView("Search an address", systemImage: "mappin.and.ellipse",
                description: Text("Start typing to see suggestions, or bookmark places in Settings."))
                .listRowSeparator(.hidden)
        } else {
            Section("Saved Places") {
                ForEach(places) { place in
                    Button { pick(PickedLocation(address: place.address, coordinate: place.coordinate)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: place.icon).foregroundStyle(.blue).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.label).font(.subheadline.weight(.medium))
                                Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        ForEach(Array(completer.results.enumerated()), id: \.offset) { _, result in
            Button { Task { await select(result) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(.subheadline)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        defer { resolving = false }
        if let picked = await completer.resolve(completion) {
            pick(picked)
        }
    }

    private func pick(_ picked: PickedLocation) {
        onPick(picked)
        dismiss()
    }
}
