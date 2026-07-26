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
    @State private var showsStaleLockAlert = false

    /// Distance, date, vehicle become read-only on a locked trip.
    private var isLocked: Bool { trip.isLocked }

    /// Only own-car trips are personally reimbursed at the mileage rate —
    /// a company car's costs are covered directly by the company (that's
    /// what the Potni Nalog logbook is for), matching
    /// PDFReporter.ownCarCandidates' own vehicle-type filter. This screen
    /// previously showed a reimbursement figure for every trip regardless
    /// of vehicle type (round-10 adversarial review finding).
    private var isOwnCarTrip: Bool { store.vehicle(trip.vehicleID)?.type == .own }

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
                // Type directly determines the reimbursement figure the
                // lock exists to freeze (Trip.reimbursement() pays a
                // different rate — or zero — per type), so it must be
                // exactly as immutable as Distance below once locked.
                // Previously only Distance had this guard, leaving the one
                // field that actually controls the reported €-amount fully
                // editable on an already-reported, locked trip (round-12
                // adversarial review finding).
                .disabled(isLocked)
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

            // Hidden until the trip is actually saved: `receipts.trip_id`
            // has a real foreign key to trips(id), and a brand-new trip's
            // row doesn't exist yet until `onSave`/`store.addTrip` runs —
            // attaching a receipt from this screen before that would
            // upload the photo to Storage and then fail the insert every
            // single time, with a generic error giving no hint why (round-8
            // adversarial review finding).
            if isNew {
                Section {
                    Text("Save this trip first, then add receipts from the trip's detail screen.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                ReceiptsSection(tripID: trip.id, receipts: $receipts)
            }

            if isOwnCarTrip {
                Section {
                    LabeledContent("Reimbursement",
                                   value: String(format: "€ %.2f", trip.reimbursement(
                                    businessRate: store.settings.reimbursementRate,
                                    commuteRate: store.settings.commuteRate
                                   )))
                }
            }
        }
        .navigationTitle(isNew ? "Classify trip" : "Edit trip")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneToolbar()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    // This screen's `@State trip` was seeded once, when it
                    // was first pushed — it doesn't refresh just because the
                    // live trip changed while this screen stayed open. Two
                    // ways that happens: (1) it got locked elsewhere
                    // ("Apply locks now", or the automatic lockAfterDays
                    // sweep re-running on foreground), or (2) TripDetector's
                    // own brief-stop merge resumed and re-ended it under the
                    // SAME id with different final mileage — `endedAt`
                    // changing is the same cheap "this got re-ended" marker
                    // TripDetector's own geocode-backfill Task already uses
                    // for an identical check (round-14 adversarial review
                    // finding). `Store.updateTrip`'s merge already refuses
                    // to apply distance/type from a stale snapshot in
                    // either case, but saving straight through would give
                    // zero indication anything didn't apply (round-12/14
                    // findings) — check freshness first.
                    if let live = store.trips.first(where: { $0.id == trip.id }),
                       (!isLocked && live.isLocked) || live.endedAt != trip.endedAt {
                        showsStaleLockAlert = true
                    } else {
                        onSave(trip)
                        dismiss()
                    }
                } label: {
                    Text("Save")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.brandGradient)
                        .clipShape(Capsule())
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
        .alert("This trip changed while open", isPresented: $showsStaleLockAlert) {
            Button("OK") {
                onSave(trip)
                dismiss()
            }
        } message: {
            Text("It was locked or updated elsewhere while open, so mileage and type can't be changed here — those edits were discarded. Purpose, customer and notes were saved.")
        }
    }
}
