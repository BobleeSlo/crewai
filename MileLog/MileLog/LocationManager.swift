import Foundation
import CoreLocation
import Combine

/// Tracks a driving session and accumulates distance from GPS updates.
///
/// MVP behaviour: the user taps Start/Stop and distance is measured while the app
/// is in use. Fully automatic background trip detection (significant-location /
/// visit monitoring) is a later phase — see README.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var isTracking = false
    @Published var distanceKm: Double = 0
    @Published var authorized = false
    /// Finer-grained than `authorized` — lets the UI tell "never asked yet"
    /// apart from "the user actually said no," so it doesn't show a
    /// "go to Settings" message before the system prompt has even been
    /// answered (round-1 UX review finding).
    @Published private(set) var permission: CLAuthorizationStatus = .notDetermined

    /// Set by MileLogApp so the manual recorder refuses to start while
    /// the auto detector has a trip in progress.
    weak var detector: TripDetector?
    /// Set by MileLogApp so `discardIfTracking()` leaves a trace, matching
    /// `TripDetector.discardActiveTripForAccountSwitch()`'s explicit
    /// warning for the same class of event (round-8 adversarial review
    /// finding — this discard previously left zero record anywhere).
    weak var detectionLog: DetectionLog?

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

    /// Returns false if the manual recorder refused to start — either
    /// because the auto-detect engine is already tracking a trip (the UI
    /// should show a warning to avoid double-recording), or because
    /// location access isn't authorized. The latter used to be missed
    /// entirely: `start()` set `isTracking = true` unconditionally, so a
    /// denied-permission recording looked fully "live" (pulsing dot,
    /// ticking Stop button) while CoreLocation silently never delivered a
    /// single fix — `didFailWithError` is an explicit no-op below — leaving
    /// the user with a 0.0 km, GPS-less trip and zero indication anything
    /// was ever wrong (round-1 UX review finding: this broke the app's
    /// single most core task for anyone who'd declined the location
    /// prompt).
    @discardableResult
    func start() -> Bool {
        if detector?.activeTrip != nil {
            return false
        }
        guard authorized else { return false }
        distanceKm = 0
        lastLocation = nil
        startLocation = nil
        endLocation = nil
        startedAt = Date()
        isTracking = true
        // Without this, the manual recorder silently stopped accumulating
        // distance the moment the phone auto-locked or the user switched
        // apps — i.e. during most of any real drive. TripDetector's
        // automatic path sets this at all four of its own start sites
        // precisely because (per docs/TRACKING-AUDIT-2026-07-22.md) iOS
        // only grants sustained background runtime to apps using
        // `allowsBackgroundLocationUpdates` with active location updates.
        // The manual Start/Stop path never got the same treatment, so a
        // manually-recorded trip would come out silently truncated — or,
        // if the process was killed while suspended, lost entirely — with
        // no warning anywhere on a screen whose live hero badge is
        // explicitly designed to be glanced at while driving (round-4 UX
        // review finding). Requires the "location" background mode, which
        // this target already declares for the auto-detect path.
        manager.allowsBackgroundLocationUpdates = true
        // Re-apply the current preset here rather than only at init: the
        // user may have changed energy mode between recordings, and
        // pausesLocationUpdatesAutomatically in particular decides whether
        // iOS may silently stop updates mid-trip.
        energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        return true
    }

    func stop() {
        isTracking = false
        manager.stopUpdatingLocation()
        // Hand back the background-location privilege (and its status-bar
        // indicator) as soon as the recording is actually over.
        manager.allowsBackgroundLocationUpdates = false
        endLocation = lastLocation
    }

    /// Stops and discards an in-progress manual recording WITHOUT finalizing
    /// it — unlike `stop()`, which leaves `distanceKm`/`startLocation`/
    /// `endLocation` in place for `RecordTripView.finalizeTrip()` to save
    /// moments later. Called when the signed-in account is about to change:
    /// a manual recording spanning that boundary can't be safely attributed
    /// to either account, the same reasoning as
    /// `TripDetector.discardActiveTripForAccountSwitch()` (round-7
    /// adversarial review finding — the manual-recording path had no
    /// equivalent at all).
    func discardIfTracking() {
        guard isTracking else { return }
        detectionLog?.log("Discarding in-progress manual recording — signed-in account changed mid-drive; it can't be safely attributed to either account.",
                           level: .warning)
        isTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        distanceKm = 0
        lastLocation = nil
        startLocation = nil
        endLocation = nil
        startedAt = nil
    }

    // MARK: - CLLocationManagerDelegate
    // Same nonisolated + explicit MainActor-hop pattern as TripDetector's
    // delegate conformance, rather than relying on CoreLocation's
    // undocumented-in-Swift "callbacks land on the manager's creation
    // thread" behavior plus implicit global-actor-isolated conformance
    // (adversarial review finding — flagged for consistency/enforcement).

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for loc in locations {
                // Skip inaccurate fixes. Scaled to the active energy mode
                // rather than a bare 50m constant — Low Power mode targets
                // ~100m accuracy (Settings even recommends it "for long
                // highway drives"), so a fixed 50m ceiling could reject
                // essentially every fix during a manually-recorded trip in
                // that mode, leaving distanceKm stuck near zero for the
                // whole drive. Same fix already applied to TripDetector's
                // auto-detect path; this manual-recording path had been
                // missed (round-5 adversarial review finding).
                guard loc.horizontalAccuracy >= 0,
                      loc.horizontalAccuracy < self.energyMode.maxAcceptableGPSAccuracy else { continue }

                if self.startLocation == nil { self.startLocation = loc }

                if let last = self.lastLocation {
                    let metres = loc.distance(from: last)
                    if metres > 1 { self.distanceKm += metres / 1000.0 }   // ignore GPS jitter
                }
                self.lastLocation = loc
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorized = (status == .authorizedWhenInUse || status == .authorizedAlways)
            self?.permission = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
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
