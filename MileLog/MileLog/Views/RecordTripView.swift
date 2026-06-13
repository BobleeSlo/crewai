import SwiftUI

struct RecordTripView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationManager

    @State private var selectedVehicleID: UUID?
    @State private var tripToClassify: Trip?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Picker("Vehicle", selection: $selectedVehicleID) {
                    ForEach(store.vehicles) { vehicle in
                        Text("\(vehicle.name) · \(vehicle.type.label)")
                            .tag(Optional(vehicle.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(location.isTracking)

                Text(String(format: "%.1f", location.distanceKm))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                + Text(" km")
                    .font(.title2)
                    .foregroundColor(.secondary)

                if location.isTracking {
                    Label("Recording…", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundColor(.green)
                } else if !location.authorized {
                    Text("Location access is needed to measure distance.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                Button(action: toggleTracking) {
                    Text(location.isTracking ? "Stop trip" : "Start trip")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(location.isTracking ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(selectedVehicleID == nil)
            }
            .padding()
            .navigationTitle("New trip")
            .onAppear {
                location.requestPermission()
                if selectedVehicleID == nil {
                    selectedVehicleID = store.vehicles.first?.id
                }
            }
            .sheet(item: $tripToClassify) { trip in
                ClassifyTripView(trip: trip)
            }
        }
    }

    private func toggleTracking() {
        if location.isTracking {
            location.stop()
            Task { await finalizeTrip() }
        } else {
            location.start()
        }
    }

    private func finalizeTrip() async {
        guard let vehicleID = selectedVehicleID else { return }
        let startAddress = await location.reverseGeocode(location.startLocation)
        let endAddress = await location.reverseGeocode(location.endLocation)

        tripToClassify = Trip(
            vehicleID: vehicleID,
            type: .business,
            purpose: "",
            customerName: "",
            startedAt: location.startedAt ?? Date(),
            endedAt: Date(),
            startAddress: startAddress,
            endAddress: endAddress,
            distanceKm: location.distanceKm,
            notes: "",
            isLocked: false
        )
    }
}
