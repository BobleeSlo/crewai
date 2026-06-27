import SwiftUI
import CoreLocation

struct RecordTripView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var detector: TripDetector

    @State private var selectedVehicleID: UUID?
    @State private var tripToClassify: Trip?

    /// True when the auto-detector has a trip in flight — manual button is
    /// disabled in that case so the user can't double-record.
    private var autoActive: Bool { detector.activeTrip != nil }

    /// Distance shown in the hero badge — the auto-detector's running trip
    /// takes priority over the manual recorder when both are conceptually
    /// in play.
    private var heroDistance: Double {
        detector.activeTrip?.distanceKm ?? location.distanceKm
    }

    private var heroSubtitle: String? {
        if let auto = detector.activeTrip {
            return "Auto · \(store.vehicleName(auto.vehicleID))"
        }
        if location.isTracking {
            if let id = selectedVehicleID, let v = store.vehicle(id) {
                return "Manual · \(v.name)"
            }
            return "Manual"
        }
        return nil
    }

    private var isLive: Bool { location.isTracking || autoActive }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    autoDetectToggle
                        .padding(.top, 8)

                    vehicleSelector

                    heroBadge
                        .padding(.vertical, 8)

                    if !autoActive { primaryButton }

                    if autoActive {
                        autoActiveHint
                    } else if !location.authorized && !location.isTracking {
                        permissionHint
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: 520)        // sane width on iPad / Pro Max landscape
                .frame(maxWidth: .infinity)  // and re-center the constrained block
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(backgroundWash)
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)   // avoid large-title overlap on iOS 26
            .onAppear {
                location.requestPermission()
                if selectedVehicleID == nil {
                    selectedVehicleID = store.activeVehicles.first?.id
                }
            }
            .sheet(item: $tripToClassify) { trip in
                ClassifyTripView(trip: trip)
            }
        }
    }

    // MARK: - Layers

    /// Subtle indigo wash behind the whole screen — gives the tab a
    /// distinct identity without competing with the hero badge.
    private var backgroundWash: some View {
        LinearGradient(
            colors: [
                Theme.brandStart.opacity(0.06),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    /// Quick on/off for automatic trip detection — lets the user stop
    /// background tracking when it isn't needed (vacation, weekend, personal
    /// day) without going into Settings.
    private var autoDetectToggle: some View {
        VStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { store.settings.autoDetectEnabled },
                set: { detector.setAutoDetect($0) }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: store.settings.autoDetectEnabled
                          ? "dot.radiowaves.left.and.right"
                          : "moon.zzz.fill")
                        .foregroundStyle(store.settings.autoDetectEnabled
                                         ? AnyShapeStyle(Theme.brandGradient)
                                         : AnyShapeStyle(Color.secondary))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Automatic detection")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(autoDetectStatus)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .tint(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var autoDetectStatus: String {
        guard store.settings.autoDetectEnabled else {
            return "Off — trips won't be detected automatically"
        }
        switch detector.permission {
        case .authorizedAlways:
            return detector.isEnabled ? "Watching for trips" : "Starting…"
        case .authorizedWhenInUse, .notDetermined:
            return "Needs 'Always' location — open Settings"
        case .denied, .restricted:
            return "Location denied — enable in iOS Settings"
        @unknown default:
            return "On"
        }
    }

    private var vehicleSelector: some View {
        Menu {
            ForEach(store.activeVehicles) { vehicle in
                Button {
                    selectedVehicleID = vehicle.id
                } label: {
                    HStack {
                        Text("\(vehicle.name) · \(vehicle.type.label)")
                        if vehicle.id == selectedVehicleID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: currentVehicle?.type == .company ? "car.2.fill" : "car.fill")
                    .foregroundStyle(Theme.brandGradient)
                VStack(alignment: .leading, spacing: 0) {
                    Text(currentVehicle?.name ?? "Select vehicle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    if let v = currentVehicle {
                        Text(v.type.label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(location.isTracking || autoActive)
    }

    private var currentVehicle: Vehicle? {
        selectedVehicleID.flatMap { store.vehicle($0) }
    }

    private var heroBadge: some View {
        ZStack {
            // Soft glow halo when live
            if isLive {
                Circle()
                    .fill(Theme.brandStart.opacity(0.25))
                    .frame(width: 280, height: 280)
                    .blur(radius: 30)
            }

            Circle()
                .fill(Theme.brandGradient)
                .frame(width: 240, height: 240)
                .shadow(color: Theme.brandStart.opacity(0.35), radius: 20, x: 0, y: 8)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )

            VStack(spacing: 6) {
                Text(String(format: "%.1f", heroDistance))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: heroDistance)

                Text("km")
                    .font(.title3.weight(.medium))
                    .foregroundColor(.white.opacity(0.85))

                if let subtitle = heroSubtitle {
                    HStack(spacing: 6) {
                        if isLive { PulsingDot() }
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.95))
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryButton: some View {
        Button(action: toggleTracking) {
            HStack(spacing: 8) {
                Image(systemName: location.isTracking ? "stop.fill" : "play.fill")
                Text(location.isTracking ? "Stop trip" : "Start trip")
            }
            .font(.title3.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(buttonBackground)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: buttonShadowColor, radius: 12, x: 0, y: 6)
        }
        .disabled(selectedVehicleID == nil)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if location.isTracking {
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.27, blue: 0.23),
                         Color(red: 0.95, green: 0.18, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        } else {
            Theme.brandGradient
        }
    }

    private var buttonShadowColor: Color {
        location.isTracking
            ? Color.red.opacity(0.3)
            : Theme.brandStart.opacity(0.35)
    }

    private var autoActiveHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundColor(Theme.accent)
                Text("Auto-detect is tracking. Ends on Bluetooth disconnect or after \(store.settings.stationaryTimeoutMinutes) min stationary.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }

            Button(role: .destructive) {
                detector.forceEndTrip()
            } label: {
                Label("Stop trip now", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var permissionHint: some View {
        Text("Allow location access to measure trip distance.")
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func toggleTracking() {
        if location.isTracking {
            location.stop()
            Task { await finalizeTrip() }
        } else {
            _ = location.start()
        }
    }

    private func finalizeTrip() async {
        guard let vehicleID = selectedVehicleID else { return }
        let startAddress = await location.reverseGeocode(location.startLocation)
        let endAddress = await location.reverseGeocode(location.endLocation)
        let endCoord = location.endLocation?.coordinate

        // Auto-fill customer from past trips near this destination.
        let suggestedCustomer = CustomerSuggester.suggest(near: endCoord, in: store.trips) ?? ""

        var trip = Trip(
            vehicleID: vehicleID,
            type: .business,
            purpose: "",
            customerName: suggestedCustomer,
            startedAt: location.startedAt ?? Date(),
            endedAt: Date(),
            startAddress: startAddress,
            endAddress: endAddress,
            distanceKm: location.distanceKm,
            notes: "",
            isLocked: false
        )
        trip.endLat = endCoord?.latitude
        trip.endLng = endCoord?.longitude
        tripToClassify = trip
    }
}
