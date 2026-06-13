import SwiftUI

/// Presented as a sheet right after a trip is recorded, to label it before saving.
struct ClassifyTripView: View {
    @EnvironmentObject var store: Store
    let trip: Trip

    var body: some View {
        NavigationStack {
            TripEditor(trip: trip, isNew: true) { newTrip in
                store.addTrip(newTrip)
            }
        }
    }
}
