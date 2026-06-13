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

    private(set) var startedAt: Date?
    private(set) var startLocation: CLLocation?
    private(set) var endLocation: CLLocation?

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 20          // metres between updates
        manager.activityType = .automotiveNavigation
    }

    // MARK: - Control

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        distanceKm = 0
        lastLocation = nil
        startLocation = nil
        endLocation = nil
        startedAt = Date()
        isTracking = true
        manager.startUpdatingLocation()
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
