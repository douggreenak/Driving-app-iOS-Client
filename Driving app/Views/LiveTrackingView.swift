import SwiftUI
import MapKit
import SwiftData

struct LiveTrackingView: View {
    @Query private var vehicles: [Vehicle]

    @State private var tracker = LocationTracker()
    @State private var selectedVehicle: Vehicle?
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showingSummary = false
    @State private var showingVehiclePicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                mapLayer

                VStack {
                    if tracker.isTracking {
                        statsHUD
                    }
                    Spacer()
                    bottomControls
                }
                .padding()
            }
            .navigationTitle(tracker.isTracking ? "Tracking" : "Track Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !tracker.isTracking {
                    ToolbarItem(placement: .primaryAction) {
                        vehicleButton
                    }
                }
            }
            .onAppear {
                if tracker.authorizationStatus == .notDetermined {
                    tracker.requestPermission()
                }
                if selectedVehicle == nil {
                    selectedVehicle = vehicles.first
                }
            }
            .sheet(isPresented: $showingSummary) {
                TripSummaryView(
                    tracker: tracker,
                    vehicle: selectedVehicle,
                    onSave: saveTrip,
                    onDiscard: discardTrip
                )
            }
            .sheet(isPresented: $showingVehiclePicker) {
                VehiclePickerSheet(
                    vehicles: vehicles,
                    selected: $selectedVehicle
                )
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            if tracker.routeCoordinates.count >= 2 {
                MapPolyline(coordinates: tracker.routeCoordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            if let start = tracker.startCoordinate, tracker.isTracking {
                Annotation("Start", coordinate: start) {
                    Circle()
                        .fill(.green)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Stats HUD

    private var statsHUD: some View {
        HStack(spacing: 0) {
            statItem(
                value: String(format: "%.1f", tracker.distanceMiles),
                unit: "mi",
                icon: "point.topleft.down.to.point.bottomright.curvepath.fill"
            )
            Divider().frame(height: 40)
            statItem(
                value: tracker.formattedElapsed(),
                unit: "time",
                icon: "clock.fill"
            )
            Divider().frame(height: 40)
            statItem(
                value: String(format: "%.0f", tracker.currentSpeed),
                unit: "mph",
                icon: "speedometer"
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func statItem(value: String, unit: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .contentTransition(.numericText())
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if let vehicle = selectedVehicle, !tracker.isTracking {
                vehicleChip(vehicle)
            }

            if tracker.isTracking {
                // Gas estimate while driving
                if let mpg = selectedVehicle?.avgMpg, mpg > 0 {
                    let gallons = tracker.estimatedGallons(mpg: mpg)
                    HStack {
                        Image(systemName: "fuelpump.fill")
                            .foregroundStyle(.orange)
                        Text(String(format: "~%.2f gal used", gallons))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if let avg = selectedVehicle?.avgMpg {
                            Text(String(format: "(%.0f MPG)", avg))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
                }

                stopButton
            } else {
                startButton
            }
        }
    }

    private func vehicleChip(_ vehicle: Vehicle) -> some View {
        Button {
            showingVehiclePicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "car.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vehicle.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if let mpg = vehicle.avgMpg {
                        Text(String(format: "%.0f MPG", mpg))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var vehicleButton: some View {
        Button {
            showingVehiclePicker = true
        } label: {
            Label(selectedVehicle?.name ?? "Vehicle", systemImage: "car.fill")
        }
    }

    // MARK: - Start / Stop Buttons

    private var startButton: some View {
        Button {
            withAnimation(.spring(duration: 0.4)) {
                tracker.startTracking()
                cameraPosition = .userLocation(fallback: .automatic)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.title3)
                Text("Start Tracking")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.green.gradient, in: .capsule)
            .shadow(color: .green.opacity(0.4), radius: 12, y: 4)
        }
        .disabled(tracker.authorizationStatus == .denied || tracker.authorizationStatus == .restricted)
    }

    private var stopButton: some View {
        Button {
            withAnimation(.spring(duration: 0.4)) {
                tracker.stopTracking()
            }
            showingSummary = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "stop.fill")
                    .font(.title3)
                Text("Stop")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.red.gradient, in: .capsule)
            .shadow(color: .red.opacity(0.4), radius: 12, y: 4)
        }
    }

    // MARK: - Save / Discard

    private func saveTrip(category: TripCategory, notes: String?) {
        guard let start = tracker.startCoordinate, let end = tracker.endCoordinate else { return }

        let dist = tracker.distanceMiles
        let dur = tracker.durationMinutes

        Task { @MainActor in
            let startAddr = await reverseGeocode(start)
            let endAddr = await reverseGeocode(end)

            let f = ISO8601DateFormatter()
            let create = APITripCreate(
                date: f.string(from: .now),
                startAddress: startAddr,
                endAddress: endAddr,
                startLat: start.latitude,
                startLng: start.longitude,
                endLat: end.latitude,
                endLng: end.longitude,
                distance: dist,
                duration: dur,
                notes: notes,
                category: category.rawValue
            )
            _ = try? await APIClient.createTrip(create)
            showingSummary = false
        }
    }

    private func discardTrip() {
        showingSummary = false
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String {
        let fallback = String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return fallback
        }
        do {
            let items = try await request.mapItems
            if let name = items.first?.name, !name.isEmpty {
                return name
            }
        } catch {}
        return fallback
    }
}

// MARK: - Vehicle Picker Sheet

struct VehiclePickerSheet: View {
    let vehicles: [Vehicle]
    @Binding var selected: Vehicle?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vehicles.isEmpty {
                    ContentUnavailableView(
                        "No Vehicles",
                        systemImage: "car.fill",
                        description: Text("Add a vehicle in Settings first")
                    )
                } else {
                    ForEach(vehicles) { vehicle in
                        Button {
                            selected = vehicle
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vehicle.name)
                                        .font(.headline)
                                    Text(vehicleSubtitle(vehicle))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == vehicle.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Select Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func vehicleSubtitle(_ v: Vehicle) -> String {
        var parts: [String] = []
        if let y = v.year { parts.append(String(y)) }
        if let m = v.make { parts.append(m) }
        if let mo = v.model { parts.append(mo) }
        if let mpg = v.avgMpg { parts.append(String(format: "%.0f MPG", mpg)) }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }
}
