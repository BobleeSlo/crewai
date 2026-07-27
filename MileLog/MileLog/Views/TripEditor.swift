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
    @State private var showsInProgressAlert = false
    @State private var showsDiscardConfirm = false
    @State private var showsFullScreenMap = false

    /// Distance, date, vehicle become read-only on a locked trip.
    private var isLocked: Bool { trip.isLocked }

    /// Only own-car trips are personally reimbursed at the mileage rate —
    /// a company car's costs are covered directly by the company (that's
    /// what the Potni Nalog logbook is for), matching
    /// PDFReporter.ownCarCandidates' own vehicle-type filter. This screen
    /// previously showed a reimbursement figure for every trip regardless
    /// of vehicle type (round-10 adversarial review finding).
    private var isOwnCarTrip: Bool { store.vehicle(trip.vehicleID)?.type == .own }

    /// ALL vehicles, active or archived — not just `store.activeVehicles`
    /// plus whichever one happens to be currently selected. This screen's
    /// whole purpose is correcting a mis-attributed vehicle, and the
    /// CORRECT one may well be exactly the one that's since been archived
    /// (TripDetector's own auto-detect fallback only ever guesses among
    /// *active* vehicles, so "the guess is active but the real one is
    /// archived" is precisely the case this feature exists to fix) — a
    /// list built from `trip.vehicleID` would never offer that archived
    /// vehicle unless it already happened to be the (wrong) current
    /// assignment, and would silently drop it from the list the moment the
    /// user picked something else, with no way back short of discarding
    /// the screen (round-17 adversarial review finding).
    private var vehicleOptions: [Vehicle] {
        store.vehicles.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
            return lhs.name < rhs.name
        }
    }

    /// The Save button's action: check the on-screen copy is still fresh,
    /// then either save or raise the matching alert.
    ///
    /// Lifted out of `body` because the type-checker could not solve the
    /// enclosing expression in reasonable time. `body` is a single `some
    /// View` expression covering the whole Form and toolbar, and every
    /// closure inside it is part of that one solve; a method has an
    /// explicit signature, so it gets checked on its own.
    private func attemptSave() {
        // This screen's `@State trip` was seeded once, when it was first
        // pushed — it doesn't refresh just because the live trip changed
        // while this screen stayed open. Two ways that happens: (1) it got
        // locked elsewhere ("Apply locks now", or the automatic
        // lockAfterDays sweep re-running on foreground), or (2)
        // TripDetector's own brief-stop merge resumed and re-ended it under
        // the SAME id with different final mileage — `endedAt` changing is
        // the same cheap "this got re-ended" marker TripDetector's own
        // geocode-backfill Task already uses for an identical check
        // (round-14 adversarial review finding). `Store.updateTrip`'s merge
        // already refuses to apply distance/type from a stale snapshot in
        // either case, but saving straight through would give zero
        // indication anything didn't apply (round-12/14 findings) — check
        // freshness first.
        let live: Trip? = store.trips.first { $0.id == trip.id }
        if !isNew, live == nil {
            // Not locked-elsewhere and not merely re-ended — the trip has
            // been pulled OUT of store.trips entirely, which only happens
            // when TripDetector's brief-stop merge reclaims it as an
            // in-progress drive again (same reasoning NotificationManager's
            // "back in progress" handling already relies on for the
            // identical scenario). Saving now would fall through to
            // Store.addTrip's un-merged fallback — bypassing every
            // field-level protection this whole mechanism exists for — and
            // then get silently clobbered again the moment the resumed
            // drive truly ends. Block entirely rather than pretending to
            // save (round-15 adversarial review finding).
            showsInProgressAlert = true
        } else if let live,
                  (!isLocked && live.isLocked) || live.endedAt != trip.endedAt {
            showsStaleLockAlert = true
        } else {
            onSave(trip)
            dismiss()
        }
    }

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
                            Text("Mileage, date, vehicle and type can no longer be edited. Edits to purpose, customer and notes are recorded in the compliance audit log.")
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

            Section("Vehicle") {
                Picker("Vehicle", selection: $trip.vehicleID) {
                    ForEach(vehicleOptions) { vehicle in
                        Text(vehicle.isActive ? vehicle.name : "\(vehicle.name) (archived)").tag(vehicle.id)
                    }
                }
                .disabled(isLocked)
            } footer: {
                // Auto-detection's Bluetooth-fallback path can occasionally
                // guess the wrong vehicle when no BT pairing is available
                // (first drive in an unpaired car, a rental, a BT hiccup at
                // start) — TripDetector logs a "verify this trip's vehicle
                // is correct" warning to the Detection Log when that
                // happens, but until now there was no way to actually act
                // on it: this screen had no vehicle control at all, so a
                // mis-guessed vehicle silently and permanently misattributed
                // the trip to the wrong reimbursement pool or company-car
                // logbook (round-16 adversarial review finding).
                if !isLocked {
                    Text("Auto-detected trips occasionally guess the wrong vehicle if Bluetooth didn't pair. Correct it here if needed.")
                        .font(.caption)
                }
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
                    Button {
                        showsFullScreenMap = true
                    } label: {
                        TripMapView(points: tripPoints)
                            .frame(height: 180)
                            .listRowInsets(EdgeInsets())
                            .allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                    Text("\(tripPoints.count) points recorded · tap the map to zoom in")
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
                Button(action: attemptSave) {
                    SaveButtonLabel()
                }
            }
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    // This button used to dismiss instantly with no
                    // confirmation — undermining the `.interactiveDismiss
                    // Disabled()` a few lines up in RecordTripView, which
                    // exists specifically because a fully GPS-measured,
                    // unsaved trip shouldn't vanish from one ordinary tap
                    // (round-1 UX review finding: the swipe was blocked,
                    // but this button offered the identical, total,
                    // unconfirmed loss).
                    Button("Discard", role: .destructive) {
                        showsDiscardConfirm = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Discard this trip?",
            isPresented: $showsDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Its distance and route were measured by GPS and haven't been saved. This can't be undone.")
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
        .alert("This trip is back in progress", isPresented: $showsInProgressAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("The car started moving again before you saved, so this was merged back into an ongoing drive. Your edits weren't saved — reclassify it once the drive ends.")
        }
        .fullScreenCover(isPresented: $showsFullScreenMap) {
            NavigationStack {
                TripMapView(points: tripPoints, isInteractive: true)
                    .ignoresSafeArea()
                    .navigationTitle("Route")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showsFullScreenMap = false }
                        }
                    }
            }
        }
    }
}

/// The Save button's pill label, pulled out of `body`.
///
/// Inline, this six-modifier chain sat inside an already very large
/// `body`, and the type-checker gave up on the whole expression:
/// "unable to type-check this expression in reasonable time". The chain
/// is not unusual on its own — it is the size of the enclosing
/// expression that defeats the solver. Giving it its own `View` caps the
/// work at this small scope, and the leading-dot shorthands are spelled
/// out so nothing has to be inferred from context.
private struct SaveButtonLabel: View {
    var body: some View {
        Text("Save")
            .font(Font.subheadline.weight(.semibold))
            .foregroundColor(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.brandGradient)
            .clipShape(Capsule())
    }
}
