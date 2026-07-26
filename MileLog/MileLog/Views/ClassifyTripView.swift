import SwiftUI

/// Presented as a sheet right after a trip is recorded, to label it before saving.
struct ClassifyTripView: View {
    @EnvironmentObject var store: Store
    let trip: Trip

    var body: some View {
        NavigationStack {
            TripEditor(trip: trip, isNew: true) { newTrip in
                var reviewed = newTrip
                // A manually-recorded trip is inherently human-reviewed —
                // mark it so TripDetector's auto-detect merge logic never
                // treats it as a continuation point for an unrelated
                // auto-detected drive in the same vehicle (Trip.reviewedAt's
                // doc comment).
                reviewed.reviewedAt = Date()
                store.addTrip(reviewed)
            }
        }
    }
}
