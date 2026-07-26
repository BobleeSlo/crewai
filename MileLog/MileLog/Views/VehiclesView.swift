import SwiftUI

struct VehiclesView: View {
    @EnvironmentObject var store: Store
    @State private var editingVehicle: Vehicle?
    @State private var showingAdd = false

    /// Confirmation alert state for "Delete permanently" on an archived vehicle.
    @State private var permanentDeleteCandidate: Vehicle?
    /// Swipe-to-delete on an active vehicle previously called
    /// `store.deleteVehicle` directly with zero confirmation and no
    /// after-the-fact explanation — unlike `VehicleEditView`'s own "Delete
    /// vehicle" button, which explains the archive-vs-permanently-delete
    /// distinction before acting. The same destructive action had two very
    /// different levels of disclosure depending on which control the user
    /// happened to use (round-1 UX review finding).
    @State private var swipeDeleteCandidate: Vehicle?

    var body: some View {
        NavigationStack {
            Group {
                if store.activeVehicles.isEmpty && store.archivedVehicles.isEmpty
                    && store.lastSyncFailed && !store.isSyncing {
                    // "Couldn't reach your vehicles" rather than the
                    // confident "No vehicles yet" — same reasoning as
                    // TripsListView (round-5 UX review finding).
                    syncFailedState
                } else if store.activeVehicles.isEmpty && store.archivedVehicles.isEmpty && store.isSyncing {
                    // Same reasoning as TripsListView: a returning user's
                    // real vehicle list may just still be downloading on a
                    // new device (round-3 UX review finding).
                    syncingState
                } else if store.activeVehicles.isEmpty && store.archivedVehicles.isEmpty {
                    // A brand-new account has zero vehicles, and nothing
                    // else in the app works without at least one: Record's
                    // "Start trip" is silently disabled with no on-screen
                    // explanation, and auto-detect has no vehicle to ever
                    // match against. Previously this screen was just a
                    // blank list under the "Vehicles" title with no
                    // explanation and only a small "+" as the sole
                    // affordance — the one dead end a first-time user could
                    // get stuck at with zero guidance (round-1 UX review
                    // finding).
                    emptyState
                } else {
                    vehiclesList
                }
            }
            .navigationTitle("Vehicles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add vehicle")
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
            .alert("Delete permanently?",
                   isPresented: Binding(
                    get: { permanentDeleteCandidate != nil },
                    set: { if !$0 { permanentDeleteCandidate = nil } }
                   ),
                   presenting: permanentDeleteCandidate
            ) { vehicle in
                Button("Delete", role: .destructive) {
                    _ = store.deleteVehicle(vehicle)
                }
                Button("Cancel", role: .cancel) { }
            } message: { vehicle in
                Text("\"\(vehicle.name)\" will be removed from this device and your cloud backup. Only do this if no trips reference this vehicle.")
            }
            .confirmationDialog(
                "Delete \"\(swipeDeleteCandidate?.name ?? "")\"?",
                isPresented: Binding(
                    get: { swipeDeleteCandidate != nil },
                    set: { if !$0 { swipeDeleteCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let v = swipeDeleteCandidate { _ = store.deleteVehicle(v) }
                    swipeDeleteCandidate = nil
                }
                Button("Cancel", role: .cancel) { swipeDeleteCandidate = nil }
            } message: {
                if let v = swipeDeleteCandidate, store.trips.contains(where: { $0.vehicleID == v.id }) {
                    Text("This vehicle has trips attached. It will be archived so those records stay intact — you can restore it later from the Vehicles list.")
                } else {
                    Text("This vehicle has no trips and will be removed permanently.")
                }
            }
        }
    }

    private var vehiclesList: some View {
        List {
            if !store.activeVehicles.isEmpty {
                Section {
                    ForEach(store.activeVehicles) { vehicle in
                        vehicleRow(vehicle)
                    }
                    .onDelete { offsets in
                        // Ask for confirmation (with the same archive-vs-
                        // delete explanation VehicleEditView's own delete
                        // button gives) instead of deleting immediately.
                        if let first = offsets.first {
                            swipeDeleteCandidate = store.activeVehicles[first]
                        }
                    }
                }
            }

            if !store.archivedVehicles.isEmpty {
                Section {
                    ForEach(store.archivedVehicles) { vehicle in
                        archivedRow(vehicle)
                    }
                } header: {
                    SectionHeaderLabel(title: "Archived",
                                       systemImage: "archivebox")
                } footer: {
                    Text("Archived vehicles stay attached to their historical trips and reports but don't appear in pickers. Restore or delete permanently if no trips reference them.")
                        .font(.caption)
                }
            }
        }
        .refreshable { await store.retrySync() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 120, height: 120)
                    .opacity(0.12)
                Image(systemName: "car.2.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.brandGradient)
            }
            VStack(spacing: 6) {
                Text("No vehicles yet")
                    .font(.title3.bold())
                Text("Add your car to start recording trips — pair its Bluetooth here too, so auto-detect can recognize it automatically.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                showingAdd = true
            } label: {
                Label("Add vehicle", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Theme.brandGradient)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sync-failed state

    private var syncFailedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.secondary)
            VStack(spacing: 6) {
                Text("Couldn't load your vehicles")
                    .font(.title3.bold())
                Text("We couldn't reach your saved vehicles. They're safe — check your connection and try again.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                Task { await store.retrySync() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Theme.brandGradient)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Syncing state

    private var syncingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Syncing your vehicles…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Active vehicle row

    @ViewBuilder
    private func vehicleRow(_ vehicle: Vehicle) -> some View {
        Button {
            editingVehicle = vehicle
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: vehicle.type == .company ? "car.2.fill" : "car.fill")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vehicle.name).font(.headline)
                        Text(subtitle(for: vehicle))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(lastUsedLabel(vehicle))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                if store.shouldSuggestArchive(vehicle) {
                    archiveSuggestion(for: vehicle)
                }
            }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private func archiveSuggestion(for vehicle: Vehicle) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundColor(.orange)
                .font(.footnote)
            Text("Not used in 3+ months. Archive to hide from pickers?")
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
            Button("Archive") {
                _ = store.deleteVehicle(vehicle)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Archived vehicle row

    @ViewBuilder
    private func archivedRow(_ vehicle: Vehicle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(vehicle.name)
                    .strikethrough()
                    .foregroundColor(.secondary)
                Text(subtitle(for: vehicle))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                permanentDeleteCandidate = vehicle
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                store.restoreVehicle(vehicle)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
    }

    // MARK: - Helpers

    private func subtitle(for vehicle: Vehicle) -> String {
        let base = vehicle.licensePlate.isEmpty
            ? vehicle.type.label
            : "\(vehicle.type.label) · \(vehicle.licensePlate)"
        return base
    }

    private func lastUsedLabel(_ vehicle: Vehicle) -> String {
        guard let last = store.lastUsed(vehicle.id) else {
            return "Never used"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: last, relativeTo: Date())
    }
}

// MARK: - VehicleEditView ---------------------------------------------------

struct VehicleEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State var vehicle: Vehicle
    let isNew: Bool

    @State private var pairingMessage: String?
    @State private var showingDeleteConfirm = false
    @State private var deletionMessage: String?
    @State private var showsStaleLockAlert = false
    /// Snapshot of `hasLockedTrips` taken once, when the screen first
    /// appears (can't be captured in `init` — `store` isn't available via
    /// `@EnvironmentObject` until after init). Lets the Save button detect
    /// a genuine LOCKED-WHILE-OPEN transition instead of just "is this
    /// vehicle locked right now" — without it, any vehicle older than
    /// `lockAfterDays` (7 by default, and locking never reverses) would
    /// permanently show the "this vehicle changed while open" alert on
    /// every single save, including no-op saves and edits to fields that
    /// were never locked at all, which round 23's adversarial review
    /// caught as a false-alarm regression in round 22's own fix.
    @State private var wasLockedAtOpen: Bool?

    private var saveButtonEnabled: Bool {
        !vehicle.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Every reimbursement/logbook computation checks this vehicle's type
    /// via a LIVE lookup (TripEditor.isOwnCarTrip, Store.exportCSV,
    /// PDFReporter.ownCarCandidates/companyLogbookCandidates) — none of
    /// them snapshot it per-trip. Changing "My car" ↔ "Company car" after
    /// the fact retroactively reclassifies every trip ever driven in this
    /// vehicle, INCLUDING already-locked ones, completely bypassing the
    /// trip-level lock's own "once reported, immutable" guarantee with
    /// zero audit trail (round-18 adversarial review finding). Frozen once
    /// any trip referencing this vehicle is locked, mirroring the same
    /// "immutable once reported" philosophy already applied per-trip.
    ///
    /// The exact same reasoning applies to `name`/`licensePlate`/
    /// `vehicleTypeDescription`/`seatCount`: all four are printed straight
    /// from this live `Vehicle` into the own-car PDF/CSV or the potni nalog
    /// header at Generate-tap time, never snapshotted per-trip. Round 18's
    /// fix only froze `type`, leaving every other field VehicleEditView
    /// exposes fully editable — re-registering/renaming a car after some
    /// of its trips are locked would silently change what a re-generated
    /// historical Potni Nalog prints for those already-reported trips
    /// (round-19 adversarial review finding). `defaultTripType`/Bluetooth
    /// pairing are exempt: neither is ever printed on a report or affects
    /// an already-classified trip (confirmed by tracing their only call
    /// sites), so they stay freely editable regardless of lock status.
    private var hasLockedTrips: Bool {
        store.trips.contains { $0.vehicleID == vehicle.id && $0.isLocked }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Škoda Octavia)", text: $vehicle.name)
                        .disabled(hasLockedTrips)
                    TextField("License plate", text: $vehicle.licensePlate)
                        .disabled(hasLockedTrips)
                    Picker("Type", selection: $vehicle.type) {
                        ForEach(VehicleType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(hasLockedTrips)
                } header: {
                    Text("Basics")
                } footer: {
                    if hasLockedTrips {
                        Text("Can't be changed — this vehicle has locked (already-reported) trips, and these fields are printed on their reports.")
                            .font(.caption)
                    }
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

                Section {
                    // Glossed for the same reason SettingsView's own potni
                    // nalog fields were: the surrounding chrome is English,
                    // so a user who doesn't read Slovenian had no clue what
                    // to type here (round-4 UX review finding — the same
                    // gap round 2 fixed on the Settings screen, missed on
                    // this one).
                    TextField("Vrsta in tip vozila (vehicle make/type)", text: $vehicle.vehicleTypeDescription)
                        .disabled(hasLockedTrips)
                    Stepper("Število sedežev (seats): \(vehicle.seatCount)", value: $vehicle.seatCount, in: 1...9)
                        .disabled(hasLockedTrips)
                } header: {
                    Text("Potni nalog")
                } footer: {
                    Text(hasLockedTrips
                         ? "Can't be changed — printed on this vehicle's already-locked reports."
                         : "Printed in the company-car potni nalog report header.")
                        .font(.footnote)
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

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete vehicle", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("If this vehicle has trips, it will be archived (hidden from pickers but kept in your records). Otherwise it is removed permanently.")
                            .font(.caption)
                    }
                }
            }
            // The delete-confirmation overlay below (round-1 UX review
            // fix) is a small centered card, not a blocking scrim —
            // without this, every field, Save, and "Delete vehicle" stay
            // live and tappable for the full 0.9s before the sheet
            // dismisses. A stray tap on "Delete vehicle" again during that
            // window re-opens the confirmation on a vehicle that's already
            // mid-teardown (round-2 UX review finding).
            .disabled(deletionMessage != nil)
            .navigationTitle(isNew ? "Add vehicle" : "Edit vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        // This sheet's @State can go stale the same way
                        // TripEditor's does: if the app is backgrounded and
                        // foregrounded while this sheet is open,
                        // applyAutomaticLocks() (wired to every foreground
                        // transition) can lock a trip on this vehicle mid-
                        // edit. The fields react (they're disabled live via
                        // hasLockedTrips), but nothing previously stopped
                        // Save from silently discarding whatever was typed
                        // before that point — unlike TripEditor's identical
                        // case, which alerts the user instead of a silent
                        // "success" (round-22 adversarial review finding).
                        //
                        // Must compare against `wasLockedAtOpen`, not just
                        // today's `hasLockedTrips` — a vehicle older than
                        // lockAfterDays is permanently locked (locking never
                        // reverses), so checking only the current value
                        // would pop this alert on EVERY save of that
                        // vehicle forever, including no-op saves and edits
                        // to fields that were never locked at all (round-23
                        // adversarial review finding: round 22's own fix
                        // had this exact false-alarm regression).
                        if !isNew && wasLockedAtOpen == false && hasLockedTrips {
                            showsStaleLockAlert = true
                        } else {
                            if isNew {
                                store.addVehicle(vehicle)
                            } else {
                                store.updateVehicle(vehicle)
                            }
                            dismiss()
                        }
                    } label: {
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(saveButtonEnabled ? AnyShapeStyle(Theme.brandGradient)
                                                          : AnyShapeStyle(Color.gray.opacity(0.3)))
                            .clipShape(Capsule())
                    }
                    .disabled(!saveButtonEnabled || deletionMessage != nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    // `.disabled(deletionMessage != nil)` on the Form below
                    // doesn't reach toolbar content — it's not a descendant
                    // of the Form in the modifier chain — so Save/Cancel
                    // stayed tappable during the ~0.9s success-overlay
                    // window, letting a stray tap prematurely dismiss the
                    // confirmation message (round-3 UX review finding).
                    Button("Cancel") { dismiss() }
                        .disabled(deletionMessage != nil)
                }
            }
            .confirmationDialog(
                "Delete \"\(vehicle.name)\"?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let mode = store.deleteVehicle(vehicle)
                    deletionMessage = mode == .soft
                        ? "Vehicle archived (kept for trip history)."
                        : "Vehicle deleted."
                    // Pop after a brief pause so the user sees what happened
                    // — actually shown now via the `.overlay` below.
                    // `deletionMessage` was previously set but never
                    // rendered anywhere in this file, so the soft-archive-
                    // vs-hard-delete distinction this whole flow exists to
                    // communicate never reached the user at the one moment
                    // it's confirmed to have happened (round-1 UX review
                    // finding).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if store.trips.contains(where: { $0.vehicleID == vehicle.id }) {
                    Text("This vehicle has trips attached. It will be archived so those records stay intact — you can restore it later from the Vehicles list.")
                } else {
                    Text("This vehicle has no trips and will be removed permanently.")
                }
            }
            .alert("This vehicle changed while open", isPresented: $showsStaleLockAlert) {
                Button("OK") {
                    store.updateVehicle(vehicle)
                    dismiss()
                }
            } message: {
                Text("It now has a locked (already-reported) trip, so its name, plate, type, and Potni Nalog details can't be changed here — those edits were discarded.")
            }
            .onAppear {
                if wasLockedAtOpen == nil { wasLockedAtOpen = hasLockedTrips }
            }
            .overlay {
                if let deletionMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.brandGradient)
                        Text(deletionMessage)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(40)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: deletionMessage)
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
