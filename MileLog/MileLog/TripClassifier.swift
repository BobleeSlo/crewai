import Foundation
import CoreLocation

/// Decides the default trip type + customer for an auto-detected trip,
/// based on car, time, and start/end coordinates. Rules are checked in order
/// and the first match wins. The user can always override via the
/// classify-notification or the trip detail screen.
enum TripClassifier {

    struct Result {
        var type: TripType
        var customerName: String?
    }

    static func classify(
        vehicle: Vehicle,
        settings: UserSettings,
        startedAt: Date,
        startCoord: CLLocationCoordinate2D,
        endCoord: CLLocationCoordinate2D
    ) -> Result {

        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: startedAt) // 1=Sun, 2=Mon, ... 7=Sat
        let hour = cal.component(.hour, from: startedAt)
        let isWeekend = weekday == 1 || weekday == 7
        let isWeekday = !isWeekend

        // Rule 1: commute pattern — Home ↔ Work on a weekday at a plausible hour.
        if isWeekday, settings.hasHome, settings.hasWork,
           let homeLat = settings.homeLat, let homeLng = settings.homeLng,
           let workLat = settings.workLat, let workLng = settings.workLng {

            let home = CLLocationCoordinate2D(latitude: homeLat, longitude: homeLng)
            let work = CLLocationCoordinate2D(latitude: workLat, longitude: workLng)

            let homeToWork = within(startCoord, home, meters: 500) && within(endCoord, work, meters: 500)
            let workToHome = within(startCoord, work, meters: 500) && within(endCoord, home, meters: 500)

            if homeToWork && (6...10).contains(hour) { return Result(type: .commute, customerName: nil) }
            if workToHome && (15...20).contains(hour) { return Result(type: .commute, customerName: nil) }
        }

        // Rule 2: company car → business by default.
        if vehicle.type == .company {
            return Result(type: .business, customerName: nil)
        }

        // Rule 3: own car on weekend or outside working hours → private.
        if vehicle.type == .own && (isWeekend || hour < 7 || hour >= 20) {
            return Result(type: .privateTrip, customerName: nil)
        }

        // Rule 4: fall back to the vehicle's configured default.
        return Result(type: vehicle.defaultTripType, customerName: nil)
    }

    /// Haversine-ish, sufficient for ~kilometres of precision.
    private static func within(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, meters: Double) -> Bool {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB) <= meters
    }
}
