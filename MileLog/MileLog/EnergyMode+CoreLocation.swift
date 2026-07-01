import CoreLocation

/// Maps the user-facing `EnergyMode` enum to concrete CLLocationManager
/// settings. Kept separate from `Models.swift` so the model layer stays
/// free of CoreLocation dependencies.
extension EnergyMode {

    /// Desired GPS accuracy in metres (`kCLLocationAccuracy*`).
    var desiredAccuracy: CLLocationAccuracy {
        switch self {
        case .lowPower:     return kCLLocationAccuracyHundredMeters
        case .balanced:     return kCLLocationAccuracyNearestTenMeters
        case .highAccuracy: return kCLLocationAccuracyBest
        }
    }

    /// Minimum metres of movement between location callbacks. Larger
    /// values mean fewer updates → less radio + CPU wakeups.
    var distanceFilter: CLLocationDistance {
        switch self {
        case .lowPower:     return 50
        case .balanced:     return 10
        case .highAccuracy: return 5
        }
    }

    /// Whether to let iOS pause GPS automatically when the user appears
    /// stationary. True is most battery-friendly but means the system
    /// decides when updates resume; we keep it off for our normal modes
    /// so the in-app stationary watchdog stays in charge.
    var pausesLocationUpdatesAutomatically: Bool {
        self == .lowPower
    }

    /// Apply the mode to a manager — call this whenever updates are
    /// about to start, and after the user changes the mode in Settings.
    func apply(to manager: CLLocationManager) {
        manager.desiredAccuracy = desiredAccuracy
        manager.distanceFilter = distanceFilter
        manager.pausesLocationUpdatesAutomatically = pausesLocationUpdatesAutomatically
    }
}
