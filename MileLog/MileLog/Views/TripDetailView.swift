import SwiftUI

struct TripDetailView: View {
    @EnvironmentObject var store: Store
    let trip: Trip

    var body: some View {
        TripEditor(trip: trip, isNew: false) { updated in
            var reviewed = updated
            // Marks this trip as human-reviewed so TripDetector's merge/
            // reclaim logic refuses to ever resurrect it as in-progress
            // again — see Trip.reviewedAt's doc comment for why.
            reviewed.reviewedAt = Date()
            store.updateTrip(reviewed)
        }
    }
}
