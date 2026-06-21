import Foundation
import CoreLocation
import AVFoundation
import Combine

/// In-progress auto trip kept on disk so it survives the app being killed.
struct ActiveTripState: Codable {
    var id: UUID
    var vehicleID: UUID
    var audioDeviceUID: String?
    var startedAt: Date
    var startLat: Double
    var startLng: Double
    var lastLat: Double
    var lastLng: Double
    var distanceKm: Double
    var lastMovementAt: Date
    var points: [RecordedPoint] = []
}

struct RecordedPoint: Codable {
    var recordedAt: Date
    var lat: Double
    var lng: Double
    var speedKmh: Float
    var accuracyM: Float
}

/// Auto-detect engine: wakes on significant location changes, identifies the
/// car via Bluetooth audio, tracks the drive with active GPS, ends the trip on
/// BT disconnect or 5+ minutes of standing still, then saves + notifies.
///
/// Lifecycle is driven by:
///   1. CLLocationManager significant-location changes  (app wake)
///   2. Active GPS updates while a trip is running       (distance + stationary)
///   3. AVAudioSession route-change notifications        (BT disconnect)
@MainActor
final class TripDetector: NSObject, ObservableObject {

    @Published private(set) var isEnabled = false
    @Published private(set) var activeTrip: ActiveTripState?
    @Published private(set) var permission: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let motion = MotionVerifier()
    private unowned let store: Store
    private unowned let log: DetectionLog
    private weak var notifications: NotificationManager?
    /// Set by MileLogApp so the detector can refuse to start while the user
    /// is manually recording a trip with the Start/Stop button.
    weak var manualLocationManager: LocationManager?

    private let activeTripURL: URL
    private var stationaryTimer: Timer?
    /// Recurring sanity check during a trip — fires every 60s and ends the
    /// trip if either of the normal triggers (stationary, BT disconnect)
    /// failed to deliver. Logs each tick so the Detection log shows why.
    private var auditTimer: Timer?
    private let auditIntervalSeconds: TimeInterval = 60

    // Verification (candidate-trip) state — before we commit to a real Trip
    // we wait for either a sustained driving speed or CoreMotion's
    // "automotive" signal, otherwise the wake was just a walk / run.
    private struct Candidate {
        let startedAt: Date
        let startLocation: CLLocation
        var maxSpeedKmh: Double
        let confirmedByBluetooth: Bool
    }
    private var candidate: Candidate?
    private var verificationDeadline: Timer?
    private let speedConfirmKmh: Double = 25
    private let verificationSeconds: TimeInterval = 90

    init(store: Store, log: DetectionLog, notifications: NotificationManager) {
        self.store = store
        self.log = log
        self.notifications = notifications

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        activeTripURL = dir.appendingPathComponent("active-trip.json")

        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        // Battery / accuracy trade-off is owned by UserSettings.energyMode —
        // apply the current preset here, and re-apply on every trip start
        // so changes from Settings take effect immediately.
        store.settings.energyMode.apply(to: manager)
        permission = manager.authorizationStatus

        restoreActiveTripIfAny()

        if store.settings.autoDetectEnabled && permission == .authorizedAlways {
            startMonitoring()
        }
    }

    // MARK: - Public API

    /// Called when the user flips the Auto-detect toggle on.
    func requestEnable() async {
        switch permission {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // After granting "When in Use", the user can come back and tap again to upgrade.
            log.log("Requested When-in-Use; tap again after granting to request Always.", level: .info)
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            log.log("Requested Always authorization.", level: .info)
        case .authorizedAlways:
            startMonitoring()
        case .denied, .restricted:
            log.log("Location permission denied. Enable 'Always' in iOS Settings.", level: .warning)
        @unknown default:
            break
        }
    }

    func disable() {
        stopMonitoring()
        if activeTrip != nil { endTrip(reason: "disabled by user") }
    }

    /// User-initiated stop from the Record-tab banner. Records exactly why
    /// the auto trigger didn't fire (stationary time + BT presence) so the
    /// Detection log captures the post-mortem.
    func forceEndTrip() {
        guard let trip = activeTrip else {
            log.log("Force-stop tapped but no active trip.", level: .warning)
            return
        }
        let stationaryMin = Date().timeIntervalSince(trip.lastMovementAt) / 60
        let currentBT = AudioRoute.currentBluetoothOutput()
        let btStatus: String
        if let pairedUID = trip.audioDeviceUID {
            if currentBT?.uid == pairedUID {
                btStatus = "BT still connected (\(currentBT?.name ?? "?"))"
            } else if let cur = currentBT {
                btStatus = "BT changed to \(cur.name)"
            } else {
                btStatus = "BT disconnected (auto-stop should have fired)"
            }
        } else {
            btStatus = "no BT pairing at start"
        }
        log.log(String(format: "FORCE-STOP: %.1f km, %d min since last movement, %@",
                       trip.distanceKm, Int(stationaryMin), btStatus),
                level: .warning)
        endTrip(reason: "force-stopped by user")
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard !isEnabled else { return }
        manager.startMonitoringSignificantLocationChanges()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        isEnabled = true
        log.log("Auto-detect ON.", level: .info)
    }

    private func stopMonitoring() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        motion.stop()
        verificationDeadline?.invalidate()
        verificationDeadline = nil
        candidate = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        isEnabled = false
        log.log("Auto-detect OFF.", level: .info)
    }

    // MARK: - Trip start (with candidate/verification phase)

    private func handleSignificantLocation(_ location: CLLocation) {
        log.log(String(format: "Significant change @ %.4f,%.4f",
                       location.coordinate.latitude, location.coordinate.longitude))

        // Hard guards — never run two trips at the same time.
        if activeTrip != nil {
            log.log("Skipped: trip already active.")
            return
        }
        if candidate != nil {
            log.log("Skipped: candidate already pending verification.")
            return
        }
        if let manual = manualLocationManager, manual.isTracking {
            log.log("Skipped: manual recording is in progress.", level: .warning)
            return
        }

        let device = AudioRoute.currentBluetoothOutput()
        let knownVehicle = matchVehicle(for: device)

        // Fast path: if the phone is already connected to a known car's
        // Bluetooth, that's high-confidence — start the trip immediately.
        if let vehicle = knownVehicle {
            commitTripStart(at: location, startedAt: Date(),
                            vehicle: vehicle, device: device)
            return
        }

        // Slow path: no BT match. Enter verification — gather speed + CoreMotion
        // for up to `verificationSeconds`. Only then decide if this is really a drive.
        beginVerification(at: location)
    }

    private func beginVerification(at location: CLLocation) {
        candidate = Candidate(
            startedAt: Date(),
            startLocation: location,
            maxSpeedKmh: 0,
            confirmedByBluetooth: false
        )
        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        if motion.isAvailable {
            motion.start()
        } else {
            log.log("Motion API unavailable (missing NSMotionUsageDescription?); falling back to speed-only verification.", level: .warning)
        }

        verificationDeadline?.invalidate()
        verificationDeadline = Timer.scheduledTimer(withTimeInterval: verificationSeconds,
                                                    repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishVerification() }
        }
        log.log("Verification started — need speed > \(Int(speedConfirmKmh)) km/h or automotive activity.")
    }

    /// Called on every active-GPS update while in candidate mode.
    private func updateVerification(with location: CLLocation) {
        guard var c = candidate else { return }

        // Wall-clock timeout — Timer.scheduledTimer doesn't fire while iOS
        // suspends the app, so the 90s deadline can stretch to many minutes.
        // Whenever an update lands we also check elapsed time and finish if
        // the window has passed.
        if Date().timeIntervalSince(c.startedAt) >= verificationSeconds {
            finishVerification(early: false)
            return
        }

        let kmh = max(0, location.speed) * 3.6
        if kmh > c.maxSpeedKmh { c.maxSpeedKmh = kmh }
        candidate = c

        // Early confirmation: don't wait the full 90s if we already see driving.
        if kmh > speedConfirmKmh || motion.hasAutomotiveSignal {
            finishVerification(early: true)
        }
    }

    private func finishVerification(early: Bool = false) {
        guard let c = candidate else { return }
        verificationDeadline?.invalidate()
        verificationDeadline = nil

        let speedOK = c.maxSpeedKmh > speedConfirmKmh
        let autoOK  = motion.hasAutomotiveSignal
        let walkingDetected = motion.hasNonAutomotiveSignal && !autoOK

        if (speedOK || autoOK) && !walkingDetected {
            log.log(String(format: "Verification PASSED (%@): max %.1f km/h, automotive=%@",
                           early ? "early" : "timeout",
                           c.maxSpeedKmh, autoOK ? "yes" : "no"), level: .info)
            candidate = nil
            motion.stop()
            // Re-read BT now (it may have connected while we were verifying).
            let device = AudioRoute.currentBluetoothOutput()
            let vehicle = matchVehicle(for: device) ?? fallbackVehicle()
            guard let vehicle else { return }
            commitTripStart(at: c.startLocation, startedAt: c.startedAt,
                            vehicle: vehicle, device: device)
        } else {
            log.log(String(format: "Verification FAILED: max %.1f km/h, automotive=%@, walking=%@ — discarding.",
                           c.maxSpeedKmh,
                           autoOK ? "yes" : "no",
                           walkingDetected ? "yes" : "no"), level: .info)
            candidate = nil
            motion.stop()
            manager.stopUpdatingLocation()
        }
    }

    private func commitTripStart(at location: CLLocation, startedAt: Date,
                                 vehicle: Vehicle, device: BluetoothAudioDevice?) {
        let state = ActiveTripState(
            id: UUID(),
            vehicleID: vehicle.id,
            audioDeviceUID: device?.uid,
            startedAt: startedAt,
            startLat: location.coordinate.latitude,
            startLng: location.coordinate.longitude,
            lastLat: location.coordinate.latitude,
            lastLng: location.coordinate.longitude,
            distanceKm: 0,
            lastMovementAt: Date(),
            points: [RecordedPoint(
                recordedAt: location.timestamp,
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speedKmh: Float(max(0, location.speed) * 3.6),
                accuracyM: Float(location.horizontalAccuracy)
            )]
        )
        activeTrip = state
        persistActiveTrip()

        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        startAuditTimer()

        let bt = device.map { "BT \($0.name)" } ?? "no BT"
        log.log("Trip started: \(vehicle.name) [\(bt)] · \(store.settings.energyMode.label)", level: .info)
    }

    // MARK: - Audit (backup stationary + BT-disappeared detection)

    private func startAuditTimer() {
        auditTimer?.invalidate()
        // The Timer fires on the current run loop; we don't capture self in
        // the outer closure (no reference) — the inner Task captures self
        // explicitly weak, which silences the Swift 6 'captured var self'
        // warning that would fire on an implicit self.
        auditTimer = Timer.scheduledTimer(withTimeInterval: auditIntervalSeconds,
                                          repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.auditActiveTrip()
            }
        }
    }

    private func stopAuditTimer() {
        auditTimer?.invalidate()
        auditTimer = nil
    }

    /// Runs every `auditIntervalSeconds`. Catches the two cases where the
    /// normal triggers can silently miss:
    ///   1) GPS updates stop coming (iOS paused, low power) so the
    ///      per-update stationary check never runs.
    ///   2) AVAudioSession route-change notification didn't fire / was
    ///      lost while the app was suspended.
    private func auditActiveTrip() {
        guard let trip = activeTrip else {
            stopAuditTimer()
            return
        }

        let stationaryMin = Date().timeIntervalSince(trip.lastMovementAt) / 60
        let timeout = Double(store.settings.stationaryTimeoutMinutes)

        // BT audit: if the paired device is no longer in the current audio
        // route, treat it as a disconnect that the system notification missed.
        if let pairedUID = trip.audioDeviceUID {
            let currentUID = AudioRoute.currentBluetoothOutput()?.uid
            if currentUID != pairedUID {
                log.log("AUDIT: paired BT device gone from audio route — ending trip.",
                        level: .info)
                endTrip(reason: "BT disconnected (audit)")
                return
            }
        }

        // Stationary audit.
        if stationaryMin >= timeout {
            log.log(String(format: "AUDIT: %.0f min stationary >= %.0f min threshold — ending trip.",
                           stationaryMin, timeout), level: .info)
            endTrip(reason: "stationary \(Int(stationaryMin)) min (audit)")
            return
        }

        // Heartbeat — proves the audit is alive and reveals why we're not stopping.
        log.log(String(format: "AUDIT heartbeat: %.1f km · %.0f min since last movement (threshold %.0f) · BT %@",
                       trip.distanceKm,
                       stationaryMin,
                       timeout,
                       trip.audioDeviceUID == nil ? "n/a" : "ok"))
    }

    /// When no BT match is available, prefer the vehicle from the user's most
    /// recent trip instead of arbitrarily picking the first one in the list.
    private func fallbackVehicle() -> Vehicle? {
        if let latest = store.trips.sorted(by: { $0.startedAt > $1.startedAt }).first,
           let v = store.vehicle(latest.vehicleID) {
            return v
        }
        return store.vehicles.first
    }

    private func matchVehicle(for device: BluetoothAudioDevice?) -> Vehicle? {
        guard let device else { return nil }
        if let v = store.vehicles.first(where: { !$0.bluetoothUID.isEmpty && $0.bluetoothUID == device.uid }) {
            return v
        }
        if let v = store.vehicles.first(where: { !$0.bluetoothName.isEmpty && $0.bluetoothName == device.name }) {
            return v
        }
        return nil
    }

    // MARK: - Trip progress

    private func updateActiveTrip(with location: CLLocation) {
        guard var trip = activeTrip else { return }
        let previous = CLLocation(latitude: trip.lastLat, longitude: trip.lastLng)
        let metres = location.distance(from: previous)
        if metres > 10 {
            trip.distanceKm += metres / 1000.0
            trip.lastLat = location.coordinate.latitude
            trip.lastLng = location.coordinate.longitude
            trip.points.append(RecordedPoint(
                recordedAt: location.timestamp,
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speedKmh: Float(max(0, location.speed) * 3.6),
                accuracyM: Float(location.horizontalAccuracy)
            ))
            // Distance-based movement check: with distanceFilter = 10m iOS
            // often reports speed = 0 at the moment of an update (snapshot
            // between stop-and-go updates), so the speed check alone misses
            // active driving and the audit then ends the trip as 'stationary'
            // even though km kept piling up. Anything > 10m of actual GPS
            // travel is irrefutable movement.
            trip.lastMovementAt = Date()
        }
        if location.speed > 0.5 {   // > ~1.8 km/h => actually moving
            trip.lastMovementAt = Date()
        }
        activeTrip = trip
        persistActiveTrip()
        checkStationary()
    }

    private func checkStationary() {
        guard let trip = activeTrip else { return }
        let minutes = Date().timeIntervalSince(trip.lastMovementAt) / 60.0
        if minutes >= Double(store.settings.stationaryTimeoutMinutes) {
            endTrip(reason: "stationary for \(Int(minutes)) min")
        }
    }

    // MARK: - Trip end

    private func endTrip(reason: String) {
        guard let state = activeTrip else { return }

        // Discard very-short trips entirely — they're auto-detector noise
        // (the wake fired but the car only moved a few metres of GPS jitter,
        // or it ended before any meaningful movement landed). Threshold at
        // 200 m: anything shorter is below normal urban-block distance and
        // almost always GPS noise rather than a real reimbursable trip.
        let minTripKm = 0.2
        if state.distanceKm < minTripKm {
            log.log(String(format: "Trip discarded (%@): %.2f km < %.1f km threshold.",
                           reason, state.distanceKm, minTripKm), level: .info)
            manager.stopUpdatingLocation()
            motion.stop()
            stopAuditTimer()
            activeTrip = nil
            clearPersistedActiveTrip()
            return
        }

        let vehicle = store.vehicle(state.vehicleID) ?? store.vehicles.first
            ?? Vehicle(name: "Unknown", licensePlate: "", type: .own)

        let endCoord = CLLocationCoordinate2D(latitude: state.lastLat, longitude: state.lastLng)
        let startCoord = CLLocationCoordinate2D(latitude: state.startLat, longitude: state.startLng)

        let classified = TripClassifier.classify(
            vehicle: vehicle,
            settings: store.settings,
            startedAt: state.startedAt,
            startCoord: startCoord,
            endCoord: endCoord
        )

        // If we've seen a customer near this end location before, auto-fill
        // the name so the user only has to confirm via the notification.
        let learnedCustomer = CustomerSuggester.suggest(near: endCoord, in: store.trips)
        let customer = (classified.customerName?.isEmpty == false ? classified.customerName : nil)
            ?? learnedCustomer
            ?? ""

        var trip = Trip(
            id: state.id,
            vehicleID: state.vehicleID,
            type: classified.type,
            purpose: "",
            customerName: customer,
            startedAt: state.startedAt,
            endedAt: Date(),
            startAddress: "",
            endAddress: "",
            distanceKm: state.distanceKm,
            notes: "Auto-detected",
            isLocked: false
        )
        trip.endLat = state.lastLat
        trip.endLng = state.lastLng
        store.addTrip(trip)
        log.log(String(format: "Trip ended (%@): %.1f km → %@",
                       reason, state.distanceKm, classified.type.label), level: .info)

        // Notify the user so they can quick-classify.
        if let notifications {
            Task { await notifications.sendClassifyNotification(for: trip) }
        }

        // Sync the GPS polyline to Supabase so the trip detail can render the route.
        if let supabase = store.supabaseService {
            let dtos = state.points.map {
                TripPointDTO(
                    trip_id: state.id,
                    recorded_at: $0.recordedAt,
                    lat: $0.lat, lng: $0.lng,
                    speed_kmh: $0.speedKmh, accuracy_m: $0.accuracyM
                )
            }
            Task { try? await supabase.pushTripPoints(dtos) }
        }

        // Reverse-geocode start/end addresses lazily and patch the saved trip.
        // Explicit @MainActor + [storeRef] capture keeps Swift 6 strict
        // concurrency happy: storeRef is the only captured reference and
        // the actor isolation matches store.updateTrip's requirements
        // (so no await needed there — only the geocoder calls are async).
        let storeRef = store
        Task { @MainActor [trip, startCoord, endCoord, storeRef] in
            let start = await Self.reverseGeocode(startCoord)
            let end = await Self.reverseGeocode(endCoord)
            var t = trip
            t.startAddress = start
            t.endAddress = end
            storeRef.updateTrip(t)
        }

        manager.stopUpdatingLocation()
        motion.stop()
        stopAuditTimer()
        activeTrip = nil
        clearPersistedActiveTrip()
    }

    private static func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
            let parts = [placemark.thoroughfare, placemark.locality].compactMap { $0 }
            return parts.joined(separator: ", ")
        }
        return ""
    }

    // MARK: - Audio route changes (BT disconnect ends the trip)

    @objc nonisolated private func audioRouteChanged(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.log("Audio route change: \(reason)")
            if reason == .oldDeviceUnavailable, let active = self.activeTrip, active.audioDeviceUID != nil {
                self.endTrip(reason: "Bluetooth disconnected")
            }
        }
    }

    // MARK: - Persistence of active trip

    private func persistActiveTrip() {
        guard let trip = activeTrip else { return }
        try? JSONEncoder().encode(trip).write(to: activeTripURL)
    }

    private func clearPersistedActiveTrip() {
        try? FileManager.default.removeItem(at: activeTripURL)
    }

    private func restoreActiveTripIfAny() {
        guard let data = try? Data(contentsOf: activeTripURL),
              let trip = try? JSONDecoder().decode(ActiveTripState.self, from: data) else { return }
        activeTrip = trip
        log.log("Restored in-progress trip after relaunch.", level: .info)
    }
}

extension TripDetector: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.permission = status
            self.log.log("Location authorization changed: \(status.label)")
            if status == .authorizedAlways && self.store.settings.autoDetectEnabled && !self.isEnabled {
                self.startMonitoring()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activeTrip != nil {
                self.updateActiveTrip(with: loc)
            } else if self.candidate != nil {
                self.updateVerification(with: loc)
            } else {
                self.handleSignificantLocation(loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.log.log("Location error: \(error.localizedDescription)", level: .error)
        }
    }

    /// iOS itself decided we're stationary and paused GPS — happens in Low
    /// Power energy mode. Treat as a definitive stationary signal and end
    /// the trip rather than waiting for the next wake.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.log("iOS auto-paused location updates (stationary).", level: .info)
            if self.activeTrip != nil {
                self.endTrip(reason: "iOS auto-paused (stationary)")
            }
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.log.log("iOS resumed location updates.")
        }
    }
}

private extension CLAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorizedAlways:     return "always"
        case .authorizedWhenInUse:  return "whenInUse"
        @unknown default:    return "unknown"
        }
    }
}
