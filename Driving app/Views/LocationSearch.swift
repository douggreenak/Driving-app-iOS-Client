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

/// One-shot current-location fetch + reverse geocode, for the "Use current location" option.
@MainActor
@Observable
final class CurrentLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Request authorization (if needed) and return the device's current fix, or nil on failure.
    func current() async -> PickedLocation? {
        let status = manager.authorizationStatus
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
        if status == .denied || status == .restricted { return nil }
        let location: CLLocation? = await withCheckedContinuation { cont in
            continuation = cont
            manager.requestLocation()
        }
        guard let location else { return nil }
        let address = await reverseGeocode(location) ?? "Current Location"
        return PickedLocation(address: address, coordinate: location.coordinate)
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let parts = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }
        let street = parts.joined(separator: " ")
        return [street.isEmpty ? nil : street, placemark.locality]
            .compactMap { $0 }.joined(separator: ", ")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            continuation?.resume(returning: locations.last)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(returning: nil)
            continuation = nil
        }
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
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.sortOrder) private var places: [SavedPlace]
    @State private var completer = AddressCompleter()
    @State private var locator = CurrentLocationProvider()
    @State private var query = ""
    @State private var resolving = false
    @State private var showingAdd = false
    @State private var pendingDelete: SavedPlace?
    @FocusState private var focused: Bool

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if isSearching {
                    List { resultsSection }.listStyle(.plain)
                } else {
                    savedCards
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay {
                if resolving { ProgressView().controlSize(.large) }
            }
            .sheet(isPresented: $showingAdd) {
                AddBookmarkView(nextOrder: (places.map(\.sortOrder).max() ?? -1) + 1)
            }
            .confirmationDialog("Remove this saved place?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let p = pendingDelete { Haptics.warning(); context.delete(p); try? context.save() }
                    pendingDelete = nil
                }
            }
            .onAppear {
                if !initialQuery.isEmpty { query = initialQuery; completer.query = initialQuery }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for an address", text: $query)
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

    // MARK: - Saved-place cards (shown when not actively searching)

    private var savedCards: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                currentLocationCard
                ForEach(places) { place in
                    placeCard(place)
                }
                addCard
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var currentLocationCard: some View {
        Button { Task { await useCurrentLocation() } } label: {
            cardBody(icon: "location.fill", iconColor: .white, iconBackground: .blue,
                     title: "Current Location", subtitle: "Use where you are now",
                     tint: .blue.opacity(0.18))
        }
        .buttonStyle(.plain)
    }

    private func placeCard(_ place: SavedPlace) -> some View {
        Button { pick(PickedLocation(address: place.address, coordinate: place.coordinate)) } label: {
            cardBody(icon: place.icon, iconColor: .blue, iconBackground: .blue.opacity(0.15),
                     title: place.label, subtitle: place.address, tint: Color(.systemGray6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { pendingDelete = place } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var addCard: some View {
        Button { Haptics.tap(); showingAdd = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold)).foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(.blue.opacity(0.12), in: .circle)
                Text("Add Place").font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                Text("Save an address").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 116)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.blue.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }

    /// Shared card chrome: a tinted icon chip, a bold title, and a one-line subtitle.
    private func cardBody(icon: String, iconColor: Color, iconBackground: Color,
                          title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.headline).foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .background(iconBackground, in: .circle)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 116)
        .padding(12)
        .background(tint, in: .rect(cornerRadius: 16))
    }

    private func useCurrentLocation() async {
        resolving = true
        defer { resolving = false }
        if let picked = await locator.current() {
            pick(picked)
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
