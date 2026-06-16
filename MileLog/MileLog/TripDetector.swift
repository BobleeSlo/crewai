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
    private unowned let store: Store
    private unowned let log: DetectionLog
    private weak var notifications: NotificationManager?

    private let activeTripURL: URL
    private var stationaryTimer: Timer?

    init(store: Store, log: DetectionLog, notifications: NotificationManager) {
        self.store = store
        self.log = log
        self.notifications = notifications

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        activeTripURL = dir.appendingPathComponent("active-trip.json")

        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
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
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        isEnabled = false
        log.log("Auto-detect OFF.", level: .info)
    }

    // MARK: - Trip start

    private func handleSignificantLocation(_ location: CLLocation) {
        log.log(String(format: "Significant change @ %.4f,%.4f", location.coordinate.latitude, location.coordinate.longitude))
        if activeTrip == nil { startTrip(at: location) }
    }

    private func startTrip(at location: CLLocation) {
        let device = AudioRoute.currentBluetoothOutput()
        let vehicle = matchVehicle(for: device) ?? store.vehicles.first
        guard let vehicle else {
            log.log("No vehicles configured; skipping auto trip.", level: .warning)
            return
        }

        let state = ActiveTripState(
            id: UUID(),
            vehicleID: vehicle.id,
            audioDeviceUID: device?.uid,
            startedAt: Date(),
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
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()

        let bt = device.map { "BT \($0.name)" } ?? "no BT"
        log.log("Trip started: \(vehicle.name) [\(bt)]", level: .info)
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

        let trip = Trip(
            id: state.id,
            vehicleID: state.vehicleID,
            type: classified.type,
            purpose: "",
            customerName: classified.customerName ?? "",
            startedAt: state.startedAt,
            endedAt: Date(),
            startAddress: "",
            endAddress: "",
            distanceKm: state.distanceKm,
            notes: "Auto-detected",
            isLocked: false
        )
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
        Task { [trip, startCoord, endCoord] in
            let start = await Self.reverseGeocode(startCoord)
            let end = await Self.reverseGeocode(endCoord)
            var t = trip
            t.startAddress = start
            t.endAddress = end
            store.updateTrip(t)
        }

        manager.stopUpdatingLocation()
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
        Task { @MainActor in
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
        Task { @MainActor in
            self.permission = status
            self.log.log("Location authorization changed: \(status.label)")
            if status == .authorizedAlways && self.store.settings.autoDetectEnabled && !self.isEnabled {
                self.startMonitoring()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            if self.activeTrip == nil {
                self.handleSignificantLocation(loc)
            } else {
                self.updateActiveTrip(with: loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.log.log("Location error: \(error.localizedDescription)", level: .error)
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
