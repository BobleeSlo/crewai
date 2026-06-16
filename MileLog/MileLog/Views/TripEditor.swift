import SwiftUI
import MapKit

/// Shared form for classifying a new trip or editing an existing one.
struct TripEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State var trip: Trip
    let isNew: Bool
    let onSave: (Trip) -> Void

    @State private var tripPoints: [TripPointDTO] = []
    @State private var receipts: [Receipt] = []

    /// Distance, date, vehicle become read-only on a locked trip.
    private var isLocked: Bool { trip.isLocked }

    var body: some View {
        Form {
            if isLocked {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Locked entry").bold()
                            if let lockedAt = trip.lockedAt {
                                Text("Locked \(lockedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("Mileage, date and vehicle can no longer be edited. Edits to purpose, customer and notes are recorded in the compliance audit log.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    } icon: {
                        Image(systemName: "lock.fill").foregroundColor(.orange)
                    }
                }
            }

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
                        .disabled(isLocked)
                        .foregroundColor(isLocked ? .secondary : .primary)
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

            if !tripPoints.isEmpty {
                Section("GPS track") {
                    TripMapView(points: tripPoints)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                    Text("\(tripPoints.count) points recorded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ReceiptsSection(tripID: trip.id, receipts: $receipts)

            Section {
                LabeledContent("Reimbursement",
                               value: String(format: "€ %.2f", trip.reimbursement(rate: store.reimbursementRate)))
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { dismiss() }
                }
            }
        }
        .task(id: trip.id) {
            guard !isNew else { return }
            tripPoints = (try? await supabase.pullTripPoints(for: trip.id)) ?? []
            receipts = (try? await supabase.pullReceipts(for: trip.id)) ?? []
        }
    }
}
