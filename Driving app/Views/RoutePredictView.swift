import SwiftUI
import SwiftData
import MapKit

/// "Predict a Route" — a throwaway cost estimator. Pick a start, a destination, and any number of
/// intermediate stops (multi-stop), and it fetches each leg from MapKit, sums the distance and
/// time, and estimates the speed-aware fuel and its cost — without creating a scheduled drive or a
/// recorded trip. Nothing is persisted.
struct RoutePredictView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var vehicles: [Vehicle]
    @Query private var settingsList: [UserSettings]

    /// One waypoint in the plan (start, a stop, or the destination).
    struct Waypoint: Identifiable {
        let id = UUID()
        var address: String = ""
        var coordinate: CLLocationCoordinate2D?
    }

    /// A computed leg between two consecutive waypoints.
    struct Leg: Identifiable {
        let id = UUID()
        var fromLabel: String
        var toLabel: String
        var miles: Double
        var seconds: Int
        var gallons: Double
        var coordinates: [CLLocationCoordinate2D]
        var avgMph: Double { seconds > 0 ? miles / (Double(seconds) / 3600) : 0 }
    }

    @State private var waypoints: [Waypoint] = [Waypoint(), Waypoint()]
    @State private var vehicleName: String?
    @State private var legs: [Leg] = []
    @State private var calculating = false
    @State private var routeError: String?
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var fuelPrice: Double { settingsList.first?.fuelPricePerGallon ?? 3.75 }
    private var ratedMpg: Double {
        if let named = vehicles.first(where: { $0.name == vehicleName })?.avgMpg { return named }
        if let firstMpg = vehicles.first?.avgMpg { return firstMpg }
        return 25
    }

    private var readyWaypoints: [Waypoint] { waypoints.filter { $0.coordinate != nil } }
    private var canCompute: Bool { readyWaypoints.count >= 2 }

    private var totalMiles: Double { legs.reduce(0) { $0 + $1.miles } }
    private var totalSeconds: Int { legs.reduce(0) { $0 + $1.seconds } }
    private var totalGallons: Double { legs.reduce(0) { $0 + $1.gallons } }
    private var totalCost: Double { totalGallons * fuelPrice }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !legs.isEmpty { mapCard }
                    waypointsCard
                    if let routeError {
                        Label(routeError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    computeButton
                    if !legs.isEmpty { resultsCard; legsCard }
                }
                .padding()
            }
            .background(.black)
            .navigationTitle("Predict a Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { if vehicleName == nil { vehicleName = vehicles.first?.name } }
        }
    }

    // MARK: - Waypoints

    private var waypointsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.headline)
            ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, wp in
                HStack(spacing: 8) {
                    AddressPickerRow(title: label(for: index),
                                     systemImage: icon(for: index),
                                     address: binding(for: index).address,
                                     coordinate: binding(for: index).coordinate) {
                        legs = []  // any change invalidates the previous estimate
                    }
                    if waypoints.count > 2 {
                        Button {
                            waypoints.remove(at: index); legs = []
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                // Insert a new stop just before the final destination.
                waypoints.insert(Waypoint(), at: max(1, waypoints.count - 1)); legs = []
            } label: {
                Label("Add stop", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.blue)

            if !vehicles.isEmpty {
                Divider().overlay(.secondary.opacity(0.3))
                Picker("Vehicle", selection: $vehicleName) {
                    Text("Default (\(Int(ratedMpg)) MPG)").tag(String?.none)
                    ForEach(vehicles) { v in Text(v.name).tag(String?.some(v.name)) }
                }
                .onChange(of: vehicleName) { _, _ in legs = [] }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private func label(for index: Int) -> String {
        if index == 0 { return "Start" }
        if index == waypoints.count - 1 { return "Destination" }
        return "Stop \(index)"
    }
    private func icon(for index: Int) -> String {
        if index == 0 { return "flag.fill" }
        if index == waypoints.count - 1 { return "mappin" }
        return "\(index).circle.fill"
    }
    private func binding(for index: Int) -> (address: Binding<String>, coordinate: Binding<CLLocationCoordinate2D?>) {
        (Binding(get: { waypoints[index].address }, set: { waypoints[index].address = $0 }),
         Binding(get: { waypoints[index].coordinate }, set: { waypoints[index].coordinate = $0 }))
    }

    // MARK: - Compute

    private var computeButton: some View {
        Button(action: { Task { await compute() } }) {
            HStack(spacing: 10) {
                if calculating { ProgressView().tint(.white) }
                Text(calculating ? "Calculating…" : "Estimate cost")
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background((canCompute ? Color.blue : Color.gray).gradient, in: .capsule)
        }
        .disabled(!canCompute || calculating)
    }

    private func compute() async {
        let stops = readyWaypoints
        guard stops.count >= 2 else { return }
        calculating = true; routeError = nil; legs = []
        defer { calculating = false }

        var built: [Leg] = []
        for i in 1..<stops.count {
            guard let from = stops[i - 1].coordinate, let to = stops[i].coordinate else { continue }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: .init(coordinate: from))
            request.destination = MKMapItem(placemark: .init(coordinate: to))
            request.transportType = .automobile
            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
                    routeError = "Couldn't find a driving route for one of the legs."
                    return
                }
                let miles = route.distance / 1609.34
                let seconds = Int(route.expectedTravelTime)
                let avgMph = seconds > 0 ? miles / (Double(seconds) / 3600) : 0
                // Speed-aware fuel: apply the same efficiency curve as recorded trips, evaluated at
                // this leg's average speed (we have no per-second speed for a theoretical route).
                let gallons = miles / FuelModel.mpg(atMph: avgMph, ratedMpg: ratedMpg)
                built.append(Leg(fromLabel: shortAddress(stops[i - 1].address),
                                 toLabel: shortAddress(stops[i].address),
                                 miles: miles, seconds: seconds, gallons: gallons,
                                 coordinates: route.polyline.coordinates()))
            } catch {
                routeError = "Couldn't calculate the route. Check the addresses and your connection."
                return
            }
        }
        legs = built
        if let first = built.first?.coordinates.first {
            let coords = built.flatMap(\.coordinates)
            cameraPosition = .region(regionFitting(coords) ?? MKCoordinateRegion(
                center: first, span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)))
        }
    }

    // MARK: - Results

    private var resultsCard: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Estimated cost", systemImage: "dollarsign.circle.fill").font(.headline)
                Spacer()
                Text(totalCost, format: .currency(code: "USD"))
                    .font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(.green)
            }
            HStack(spacing: 0) {
                metric(String(format: "%.1f", totalMiles), "miles")
                Divider().frame(height: 34)
                metric(timeString(totalSeconds), "drive time")
                Divider().frame(height: 34)
                metric(String(format: "%.2f", totalGallons), "gallons")
            }
            Text("At \(fuelPrice, format: .currency(code: "USD"))/gal · \(Int(ratedMpg)) MPG (speed-adjusted per leg). Estimate only — not a recorded trip.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.green.opacity(0.12), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.green.opacity(0.25), lineWidth: 1))
    }

    private func metric(_ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).fontDesign(.rounded)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var legsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Legs", systemImage: "arrow.triangle.turn.up.right.diamond.fill").font(.headline)
            ForEach(Array(legs.enumerated()), id: \.element.id) { i, leg in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(leg.fromLabel) → \(leg.toLabel)").font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(String(format: "%.1f", leg.miles)) mi · \(timeString(leg.seconds)) · \(Int(leg.avgMph)) mph avg")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(leg.gallons * fuelPrice, format: .currency(code: "USD"))
                        .font(.subheadline.weight(.semibold))
                }
                if i < legs.count - 1 { Divider().overlay(.secondary.opacity(0.25)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6), in: .rect(cornerRadius: 16))
    }

    private var mapCard: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
            ForEach(legs) { leg in
                MapPolyline(coordinates: leg.coordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(readyWaypoints.enumerated()), id: \.element.id) { i, wp in
                if let c = wp.coordinate {
                    Annotation(label(for: waypoints.firstIndex(where: { $0.id == wp.id }) ?? i), coordinate: c) {
                        Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(height: 220)
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func shortAddress(_ full: String) -> String {
        full.split(separator: ",").first.map(String.init) ?? full
    }

    private func timeString(_ seconds: Int) -> String {
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }

    /// A region that fits all coordinates with a little padding.
    private func regionFitting(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coords.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.4),
                                    longitudeDelta: max(0.01, (maxLng - minLng) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }
}
