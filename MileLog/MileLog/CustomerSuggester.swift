import Foundation
import CoreLocation

/// Auto-fills the customer name on a new trip when its end location is
/// near the end location of past trips that already had a customer entered.
///
/// Strategy:
///   1. Collect every past trip with a non-empty customer name AND end coords.
///   2. Cluster them by name; for each name pick the closest historical
///      end-point to the new trip's end point.
///   3. Return the cluster name whose nearest point is within `radiusMeters`.
///      If ties, prefer the most frequently-visited name.
enum CustomerSuggester {

    static let defaultRadiusMeters: Double = 200

    static func suggest(
        near coord: CLLocationCoordinate2D?,
        in trips: [Trip],
        radiusMeters: Double = defaultRadiusMeters
    ) -> String? {
        guard let coord else { return nil }
        let target = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        struct Candidate {
            let name: String
            var minDistance: Double
            var visitCount: Int
        }

        var byName: [String: Candidate] = [:]
        for trip in trips where !trip.customerName.isEmpty {
            guard let lat = trip.endLat, let lng = trip.endLng else { continue }
            let here = CLLocation(latitude: lat, longitude: lng)
            let distance = target.distance(from: here)
            guard distance <= radiusMeters else { continue }

            if var existing = byName[trip.customerName] {
                existing.minDistance = min(existing.minDistance, distance)
                existing.visitCount += 1
                byName[trip.customerName] = existing
            } else {
                byName[trip.customerName] = Candidate(
                    name: trip.customerName,
                    minDistance: distance,
                    visitCount: 1
                )
            }
        }

        // Prefer name with more visits; break ties by closer minimum distance.
        return byName.values
            .sorted { lhs, rhs in
                if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
                return lhs.minDistance < rhs.minDistance
            }
            .first?
            .name
    }
}
