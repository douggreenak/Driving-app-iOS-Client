import SwiftUI
import MapKit
import SwiftData

struct NewTripView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var date = Date.now
    @State private var startAddress = ""
    @State private var endAddress = ""
    @State private var notes = ""
    @State private var category: TripCategory = .other
    @State private var startCoordinate: CLLocationCoordinate2D?
    @State private var endCoordinate: CLLocationCoordinate2D?
    @State private var route: MKRoute?
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var distance: Double {
        if let route { return route.distance / 1609.34 }
        guard let s = startCoordinate, let e = endCoordinate else { return 0 }
        let start = CLLocation(latitude: s.latitude, longitude: s.longitude)
        let end = CLLocation(latitude: e.latitude, longitude: e.longitude)
        return start.distance(from: end) / 1609.34
    }

    private var duration: Int {
        if let route { return Int(route.expectedTravelTime / 60) }
        return Int(distance / 35 * 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    mapSection
                    categorySection
                    formSection
                }
                .padding()
            }
            .navigationTitle("New Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTrip() }
                        .disabled(startCoordinate == nil || endCoordinate == nil)
                }
            }
        }
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(position: $cameraPosition) {
                if let s = startCoordinate {
                    Marker("Start", systemImage: "flag.fill", coordinate: s).tint(.blue)
                }
                if let e = endCoordinate {
                    Marker("End", systemImage: "mappin", coordinate: e).tint(.red)
                }
                if let route {
                    MapPolyline(route.polyline).stroke(.blue, lineWidth: 4)
                }
            }
            .frame(height: 300)
            .clipShape(.rect(cornerRadius: 16))

            if startCoordinate != nil && endCoordinate != nil {
                HStack {
                    Label(String(format: "%.1f mi", distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    Spacer()
                    Label("\(duration) min", systemImage: "clock")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .padding()
                .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
            }
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Category")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TripCategory.allCases, id: \.self) { cat in
                        Button {
                            withAnimation(.spring(duration: 0.25)) { category = cat }
                        } label: {
                            Label(cat.label, systemImage: cat.icon)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(category == cat ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var formSection: some View {
        VStack(spacing: 12) {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .padding()
                .background(Color(.systemGray6), in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Start address", text: $startAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { geocode(startAddress, isStart: true) }
                TextField("End address", text: $endAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { geocode(endAddress, isStart: false) }
                Button("Find Route") {
                    geocode(startAddress, isStart: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        geocode(endAddress, isStart: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startAddress.isEmpty || endAddress.isEmpty)
            }
            .padding()
            .background(Color(.systemGray6), in: .rect(cornerRadius: 12))

            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(3)
                .textFieldStyle(.roundedBorder)
                .padding()
                .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
        }
    }

    private func geocode(_ address: String, isStart: Bool) {
        Task {
            guard let request = MKGeocodingRequest(addressString: address) else { return }
            guard let items = try? await request.mapItems, let item = items.first else { return }
            let coord = item.placemark.coordinate
            if isStart {
                startCoordinate = coord
            } else {
                endCoordinate = coord
                calculateRoute()
            }
        }
    }

    private func calculateRoute() {
        guard let s = startCoordinate, let e = endCoordinate else { return }
        Task {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: .init(coordinate: s))
            request.destination = MKMapItem(placemark: .init(coordinate: e))
            request.transportType = .automobile
            let directions = MKDirections(request: request)
            if let response = try? await directions.calculate() {
                self.route = response.routes.first
                cameraPosition = .automatic
            }
        }
    }

    private func saveTrip() {
        guard let s = startCoordinate, let e = endCoordinate else { return }
        let trip = Trip(
            date: date,
            startAddress: startAddress, endAddress: endAddress,
            startLat: s.latitude, startLng: s.longitude,
            endLat: e.latitude, endLng: e.longitude,
            distance: distance, duration: duration,
            notes: notes.isEmpty ? nil : notes,
            category: category
        )
        modelContext.insert(trip)
        dismiss()
    }
}
