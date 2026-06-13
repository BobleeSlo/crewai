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

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Škoda Octavia)", text: $vehicle.name)
                TextField("License plate", text: $vehicle.licensePlate)
                Picker("Type", selection: $vehicle.type) {
                    ForEach(VehicleType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.segmented)
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
}
