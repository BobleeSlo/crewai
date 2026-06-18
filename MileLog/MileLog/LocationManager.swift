import Foundation
import CoreLocation
import Combine

/// Tracks a driving session and accumulates distance from GPS updates.
///
/// MVP behaviour: the user taps Start/Stop and distance is measured while the app
/// is in use. Fully automatic background trip detection (significant-location /
/// visit monitoring) is a later phase — see README.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var isTracking = false
    @Published var distanceKm: Double = 0
    @Published var authorized = false

    /// Set by MileLogApp so the manual recorder refuses to start while
    /// the auto detector has a trip in progress.
    weak var detector: TripDetector?

    /// Current battery/accuracy preset. SettingsView calls
    /// `apply(energyMode:)` whenever the user changes the picker.
    private(set) var energyMode: EnergyMode = .balanced

    private(set) var startedAt: Date?
    private(set) var startLocation: CLLocation?
    private(set) var endLocation: CLLocation?

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        // Apply the default preset; SettingsView keeps this in sync via
        // apply(energyMode:) when the user changes the picker.
        energyMode.apply(to: manager)
    }

    func apply(energyMode: EnergyMode) {
        self.energyMode = energyMode
        energyMode.apply(to: manager)
    }

    // MARK: - Control

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Returns false if the manual recorder refused to start because the
    /// auto-detect engine is already tracking a trip — the UI should show
    /// a warning in that case to avoid double-recording.
    @discardableResult
    func start() -> Bool {
        if detector?.activeTrip != nil {
            return false
        }
        distanceKm = 0
        lastLocation = nil
        startLocation = nil
        endLocation = nil
        startedAt = Date()
        isTracking = true
        manager.startUpdatingLocation()
        return true
    }

    func stop() {
        isTracking = false
        manager.stopUpdatingLocation()
        endLocation = lastLocation
    }

    // MARK: - CLLocationManagerDelegate
    // Delegate callbacks arrive on the main run loop (manager created on main thread),
    // so it is safe to mutate @Published properties here.

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            // Skip inaccurate fixes.
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { continue }

            if startLocation == nil { startLocation = loc }

            if let last = lastLocation {
                let metres = loc.distance(from: last)
                if metres > 1 { distanceKm += metres / 1000.0 }   // ignore GPS jitter
            }
            lastLocation = loc
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        authorized = (status == .authorizedWhenInUse || status == .authorizedAlways)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal; updates simply pause. Surfaced silently in the MVP.
    }

    // MARK: - Reverse geocoding

    /// Best-effort human-readable address for a coordinate ("Street, City").
    func reverseGeocode(_ location: CLLocation?) async -> String {
        guard let location else { return "" }
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
           let placemark = placemarks.first {
            let parts = [placemark.thoroughfare, placemark.locality].compactMap { $0 }
            return parts.joined(separator: ", ")
        }
        return ""
    }
}
