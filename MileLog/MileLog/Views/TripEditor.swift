import SwiftUI

/// Shared form for classifying a new trip or editing an existing one.
struct TripEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State var trip: Trip
    let isNew: Bool
    let onSave: (Trip) -> Void

    var body: some View {
        Form {
            Section("Type") {
                Picker("Type", selection: $trip.type) {
                    ForEach(TripType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Details") {
                TextField("Customer / destination", text: $trip.customerName)
                TextField("Purpose", text: $trip.purpose)
                TextField("Notes", text: $trip.notes, axis: .vertical)
            }

            Section("Route") {
                HStack {
                    Text("Distance")
                    Spacer()
                    TextField("0", value: $trip.distanceKm, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("km").foregroundColor(.secondary)
                }
                if !trip.startAddress.isEmpty {
                    LabeledContent("From", value: trip.startAddress)
                }
                if !trip.endAddress.isEmpty {
                    LabeledContent("To", value: trip.endAddress)
                }
                LabeledContent("Date", value: trip.startedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                LabeledContent("Reimbursement",
                               value: String(format: "€ %.2f", trip.reimbursement(rate: store.reimbursementRate)))
                if trip.isLocked {
                    Label("Locked entry", systemImage: "lock.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(isNew ? "Classify trip" : "Edit trip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(trip)
                    dismiss()
                }
            }
            if isNew {
                ToolbarItem(placement: .cancelAction) {
                    Button("Discard", role: .destructive) { dismiss() }
                }
            }
        }
    }
}
