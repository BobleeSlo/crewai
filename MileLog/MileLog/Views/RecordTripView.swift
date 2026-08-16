import SwiftUI
import CoreLocation
import UIKit

struct RecordTripView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var detector: TripDetector

    @State private var selectedVehicleID: UUID?
    @State private var tripToClassify: Trip?
    @State private var showingAddVehicle = false

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
                    } else if store.activeVehicles.isEmpty {
                        // Record — not Vehicles — is the very first screen
                        // shown after sign-in, and with zero vehicles the
                        // vehicle menu is empty and Start is disabled with
                        // nothing but a 0.45 dim to explain why. Auto-detect
                        // is worse: TripDetector.finishVerification drops a
                        // fully verified real drive outright when no vehicle
                        // is registered, logging only to a Settings screen a
                        // first-time user will never open. Neither path
                        // steered the user to add a vehicle first (round-4
                        // UX review finding).
                        noVehicleHint
                    } else if !location.authorized {
                        // No longer gated on `!location.isTracking` — a
                        // manual recording can no longer even start while
                        // unauthorized (see LocationManager.start()), so
                        // this now stays visible for exactly as long as the
                        // real blocker exists, instead of disappearing the
                        // instant the user taps a Start button that was
                        // silently about to record nothing (round-1 UX
                        // review finding).
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
            // `onAppear` doesn't re-fire when a vehicle is added from the
            // sheet above (this view stays mounted), so without this the
            // user would add their first vehicle and find Start STILL
            // disabled with no explanation. Also covers the first vehicle
            // arriving from a cloud sync, and the selected vehicle being
            // archived/deleted from another tab.
            .onChange(of: store.activeVehicles) { _, vehicles in
                // Never re-point an in-flight recording at a different car:
                // `finalizeTrip()` reads `selectedVehicleID` at save time,
                // and the selector is disabled while tracking, so silently
                // reassigning here (e.g. because the user archived the car
                // they're currently driving from the Vehicles tab) would
                // file the drive against the wrong vehicle with no way to
                // correct it in place — and own-car vs company-car is
                // exactly what decides reimbursement and which report the
                // trip lands in (round-5 UX review finding).
                guard !location.isTracking else { return }
                if selectedVehicleID == nil || !vehicles.contains(where: { $0.id == selectedVehicleID }) {
                    selectedVehicleID = vehicles.first?.id
                }
            }
            .sheet(item: $tripToClassify) { trip in
                ClassifyTripView(trip: trip)
                    // Nothing about this trip is persisted anywhere until
                    // the user taps Save — it lives only in `tripToClassify`
                    // (see `finalizeTrip()`). An ordinary swipe-down gesture
                    // would otherwise discard a fully GPS-measured trip with
                    // no confirmation. The sheet's own "Discard" button
                    // remains available for an explicit, intentional discard
                    // (round-9 adversarial review finding).
                    .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showingAddVehicle) {
                VehicleEditView(
                    vehicle: Vehicle(name: "", licensePlate: "", type: .own),
                    isNew: true
                )
            }
        }
    }

    /// Shown when the account has no vehicles yet — the one state where
    /// nothing on this screen can work, and where the app previously gave
    /// a brand-new user no explanation or next step at all.
    private var noVehicleHint: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "car.2.fill")
                    .foregroundStyle(Theme.brandGradient)
                Text("Add a vehicle to start tracking trips — auto-detect needs one too.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            Button {
                showingAddVehicle = true
            } label: {
                Label("Add vehicle", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        case .notDetermined:
            // Distinct from .authorizedWhenInUse below: telling the user
            // to "open Settings" here was actively wrong — iOS won't show
            // a Location entry for an app it's never asked permission for
            // yet, and this state is genuinely reachable right after
            // toggling auto-detect on, while the system prompt is still
            // pending (round-2 UX review finding). Matches SettingsView's
            // own already-correct copy for this same case.
            return "Waiting for location permission…"
        case .authorizedWhenInUse:
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
        // Stopping must always stay available even if location access was
        // revoked mid-recording (Settings can be changed while the app is
        // backgrounded) — only starting a NEW recording requires
        // authorization, matching LocationManager.start()'s own refusal
        // (round-1 UX review finding: previously a denied-permission
        // recording could still be "started" and would silently sit at
        // 0.0 km forever).
        .disabled(!location.isTracking && (selectedVehicleID == nil || !location.authorized))
        .opacity(!location.isTracking && (selectedVehicleID == nil || !location.authorized) ? 0.45 : 1)
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
                Text("Auto-detect is tracking. Ends after \(store.settings.stationaryTimeoutMinutes) min stationary.")
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
        // Distinguishes "hasn't been asked yet" (system prompt is likely
        // still on screen, or about to be) from "the user already said
        // no" — the denied case needs a way OUT (Settings), since tapping
        // Start again does nothing (round-1 UX review finding).
        VStack(spacing: 10) {
            Text(location.permission == .denied || location.permission == .restricted
                 ? "Location access is off, so this trip can't be measured. Turn it on in iOS Settings to start recording."
                 : "Allow location access to measure trip distance.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if location.permission == .denied || location.permission == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.weight(.semibold))
            }
        }
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
        // Snapshot everything from `location` BEFORE the awaits below.
        // reverseGeocode has no timeout, and if the user taps "Start trip"
        // again during that window (isTracking already flipped false by
        // stop(), so the button is immediately tappable), LocationManager.
        // start() resets distanceKm/startedAt/startLocation/endLocation for
        // the NEW recording. Reading those fields only after the awaits
        // previously let a fresh Start silently pair THIS trip's
        // just-resolved addresses with the NEW recording's zeroed
        // distance/time/coordinates — corrupting the finished drive's
        // record with no error shown anywhere (round-16 adversarial review
        // finding).
        let startLocation = location.startLocation
        let endLocation = location.endLocation
        let startedAt = location.startedAt
        let distanceKm = location.distanceKm
        let endCoord = endLocation?.coordinate
        // The actual last GPS fix's own timestamp, not "whenever the
        // reverse-geocode calls below happen to finish" — CLGeocoder has
        // no timeout and can stall for the same tunnel/dead-zone conditions
        // that are common right at a trip's end (e.g. pulling into an
        // underground garage), which would otherwise skew every manually-
        // recorded trip's official end time later than when the drive
        // actually ended, misrepresenting the record (day grouping, the
        // lockAfterDays cutoff, potni nalog arrival times) for no reason
        // (round-17 adversarial review finding). TripDetector's own
        // endTrip already captures its end timestamp synchronously before
        // any async work for the identical reason.
        let realEndedAt = endLocation?.timestamp ?? Date()

        let startAddress = await location.reverseGeocode(startLocation)
        let endAddress = await location.reverseGeocode(endLocation)

        // Auto-fill customer from past trips near this destination.
        let suggestedCustomer = CustomerSuggester.suggest(near: endCoord, in: store.trips) ?? ""

        var trip = Trip(
            vehicleID: vehicleID,
            type: .business,
            purpose: "",
            customerName: suggestedCustomer,
            startedAt: startedAt ?? Date(),
            endedAt: realEndedAt,
            startAddress: startAddress,
            endAddress: endAddress,
            distanceKm: distanceKm,
            notes: "",
            isLocked: false
        )
        trip.startLat = startLocation?.coordinate.latitude
        trip.startLng = startLocation?.coordinate.longitude
        trip.endLat = endCoord?.latitude
        trip.endLng = endCoord?.longitude
        tripToClassify = trip
    }
}
