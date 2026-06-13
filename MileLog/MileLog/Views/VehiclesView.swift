import SwiftUI

struct VehiclesView: View {
    @EnvironmentObject var store: Store
    @State private var editingVehicle: Vehicle?
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.vehicles) { vehicle in
                    Button {
                        editingVehicle = vehicle
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vehicle.name).font(.headline)
                            Text(subtitle(for: vehicle))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { store.deleteVehicle(at: $0) }
            }
            .navigationTitle("Vehicles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingVehicle) { vehicle in
                VehicleEditView(vehicle: vehicle, isNew: false)
            }
            .sheet(isPresented: $showingAdd) {
                VehicleEditView(
                    vehicle: Vehicle(name: "", licensePlate: "", type: .own),
                    isNew: true
                )
            }
        }
    }

    private func subtitle(for vehicle: Vehicle) -> String {
        vehicle.licensePlate.isEmpty
            ? vehicle.type.label
            : "\(vehicle.type.label) · \(vehicle.licensePlate)"
    }
}

struct VehicleEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State var vehicle: Vehicle
    let isNew: Bool

    @State private var pairingMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Name (e.g. Škoda Octavia)", text: $vehicle.name)
                    TextField("License plate", text: $vehicle.licensePlate)
                    Picker("Type", selection: $vehicle.type) {
                        ForEach(VehicleType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Default trip type") {
                    Picker("Default", selection: $vehicle.defaultTripType) {
                        ForEach(TripType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Used as the default classification when this vehicle's trip is auto-detected.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Car Bluetooth") {
                    if vehicle.bluetoothName.isEmpty {
                        Text("Not paired yet")
                            .foregroundColor(.secondary)
                    } else {
                        LabeledContent("Device", value: vehicle.bluetoothName)
                        if !vehicle.bluetoothUID.isEmpty {
                            LabeledContent("ID") {
                                Text(vehicle.bluetoothUID)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }

                    Button {
                        pairWithCurrentBluetooth()
                    } label: {
                        Label("Pair with current Bluetooth connection", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    if !vehicle.bluetoothName.isEmpty {
                        Button("Clear pairing", role: .destructive) {
                            vehicle.bluetoothName = ""
                            vehicle.bluetoothUID = ""
                            pairingMessage = nil
                        }
                    }

                    if let pairingMessage {
                        Text(pairingMessage)
                            .font(.footnote)
                            .foregroundColor(pairingMessage.hasPrefix("Paired") ? .green : .orange)
                    }

                    Text("Sit in the car with the engine on and your phone connected to the car audio. Then tap the button above.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(isNew ? "Add vehicle" : "Edit vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew {
                            store.addVehicle(vehicle)
                        } else {
                            store.updateVehicle(vehicle)
                        }
                        dismiss()
                    }
                    .disabled(vehicle.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pairWithCurrentBluetooth() {
        if let device = AudioRoute.currentBluetoothOutput() {
            vehicle.bluetoothName = device.name
            vehicle.bluetoothUID = device.uid
            pairingMessage = "Paired with \(device.name)"
        } else {
            pairingMessage = "No Bluetooth audio device detected. Make sure your iPhone is currently connected to the car's audio."
        }
    }
}
