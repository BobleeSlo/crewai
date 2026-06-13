import SwiftUI

struct TripDetailView: View {
    @EnvironmentObject var store: Store
    let trip: Trip

    var body: some View {
        TripEditor(trip: trip, isNew: false) { updated in
            store.updateTrip(updated)
        }
    }
}
