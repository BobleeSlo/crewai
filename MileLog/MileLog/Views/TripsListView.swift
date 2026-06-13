import SwiftUI

struct TripsListView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
            Group {
                if store.trips.isEmpty {
                    emptyState
                } else {
                    tripList
                }
            }
            .navigationTitle("Trips")
        }
    }

    private var tripList: some View {
        List {
            ForEach(store.monthSections, id: \.self) { section in
                Section {
                    ForEach(section.trips) { trip in
                        NavigationLink {
                            TripDetailView(trip: trip)
                        } label: {
                            TripRow(trip: trip)
                        }
                    }
                    .onDelete { offsets in
                        store.deleteTrips(section.trips, at: offsets)
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text(section.summary).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "car")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No trips yet")
                .font(.headline)
            Text("Record your first trip from the Record tab.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct TripRow: View {
    @EnvironmentObject var store: Store
    let trip: Trip

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.customerName.isEmpty ? trip.type.label : trip.customerName)
                    .font(.headline)
                Text("\(trip.startedAt.formatted(date: .abbreviated, time: .omitted)) · \(store.vehicleName(trip.vehicleID))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f km", trip.distanceKm))
                    .font(.subheadline.bold())
                Text(trip.type.label)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }

    private var badgeColor: Color {
        switch trip.type {
        case .business:    return .blue
        case .commute:     return .orange
        case .privateTrip: return .gray
        }
    }
}
