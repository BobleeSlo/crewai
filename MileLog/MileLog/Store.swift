import Foundation
import Combine
import SwiftUI   // for Array.remove(atOffsets:) used by ForEach.onDelete bridging

/// Local-first data store. Persists vehicles, trips and settings as JSON in the
/// app's Documents directory. Cloud (Supabase) sync is layered on top of this
/// in a later phase — see README.
@MainActor
final class Store: ObservableObject {
    @Published var vehicles: [Vehicle] = []
    @Published var trips: [Trip] = []
    @Published var settings = UserSettings()
    /// True for the duration of `initialSync`. Previously there was no
    /// signal anywhere that a sync was in flight — a returning user
    /// restoring an account with months of history on a new phone, on a
    /// slow connection, would see TripsListView's cheerful "No trips yet"
    /// empty state while their actual history was still downloading: a
    /// confident "you have nothing" where the truth was "still loading,"
    /// which is genuinely alarming for what's meant to be a defensible tax
    /// record (round-3 UX review finding).
    @Published private(set) var isSyncing = false
    /// True when the last sync couldn't DOWNLOAD that collection. Distinct
    /// from `isSyncing`: it's the difference between "still loading" and
    /// "couldn't reach your data," which the UI previously collapsed into
    /// the same confident "you have nothing yet" empty state (round-5 UX
    /// review finding). Tracked per collection so one collection's failure
    /// can't fabricate an error on the other's screen (round-6 finding).
    @Published private(set) var tripsSyncFailed = false
    @Published private(set) var vehiclesSyncFailed = false

    /// Backs pull-to-refresh and the "Try again" buttons. Deliberately does
    /// only the DOWNLOAD half, not a full bidirectional resync: routing
    /// this through `initialSync` meant every pull-to-refresh first
    /// re-uploaded the user's entire local history one awaited row at a
    /// time before a single new byte arrived — a minute-plus of pure
    /// re-upload on a year of driving, worst on exactly the slow
    /// connection that makes someone pull to refresh (round-6 UX review
    /// finding). Pushes are already retried by `initialSync` on the next
    /// sign-in and by each mutation's own push, so nothing is lost by
    /// skipping them here.
    func retrySync() async {
        guard let supabase else { return }
        isSyncing = true
        defer { isSyncing = false }

        if let cloudVehicles = try? await supabase.pullVehicles() {
            let localIDs = Set(vehicles.map(\.id))
            vehicles += cloudVehicles.filter { !localIDs.contains($0.id) && !deletedVehicleIDs.contains($0.id) }
            vehiclesSyncFailed = false
        } else {
            vehiclesSyncFailed = true
        }
        if let cloudTrips = try? await supabase.pullTrips() {
            let localIDs = Set(trips.map(\.id))
            let activeID = detector?.activeTrip?.id
            trips += cloudTrips.filter {
                !localIDs.contains($0.id) && $0.id != activeID && !deletedTripIDs.contains($0.id)
            }
            tripsSyncFailed = false
        } else {
            tripsSyncFailed = true
        }
        save()
    }

    /// Convenience accessor kept for the existing UI/CSV code.
    var reimbursementRate: Double {
        get { settings.reimbursementRate }
        set { settings.reimbursementRate = newValue; save() }
    }

    /// Set after the user signs in; when present, mutations are mirrored to Supabase.
    private weak var supabase: SupabaseService?

    /// Read-only access for collaborators (TripDetector pushes GPS points + receipts).
    var supabaseService: SupabaseService? { supabase }

    /// Set by the app on launch (weak — TripDetector already holds a strong
    /// reference to this Store, so this is the non-owning direction). Lets
    /// deleteVehicle refuse to hard-delete a vehicle that's the subject of
    /// an in-progress auto-detected trip.
    weak var detector: TripDetector?

    /// Set by the app on launch. `DetectionLog` is purely local/on-device
    /// (never synced to Supabase), but it records raw GPS coordinates,
    /// vehicle/Bluetooth device names, and per-trip timing/distance for
    /// whichever account was signed in when each entry was logged — an
    /// account switch on the same device otherwise leaves the PREVIOUS
    /// account's driving history sitting there for the NEXT account to
    /// read in Settings → Detection log (round-8 adversarial review
    /// finding: the same class of cross-account leak already fixed for
    /// trips/vehicles/settings, just in a subsystem nothing had checked).
    weak var detectionLog: DetectionLog?

    private let vehiclesURL: URL
    private let tripsURL: URL
    private let settingsURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        vehiclesURL = dir.appendingPathComponent("vehicles.json")
        tripsURL    = dir.appendingPathComponent("trips.json")
        settingsURL = dir.appendingPathComponent("settings.json")
        load()

        // Previously seeded a placeholder "My car" vehicle whenever local
        // storage was empty — but that's true not just for a genuinely
        // new account, but for ANY fresh install/reinstall/new-device
        // sign-in into an EXISTING account too, since local JSON files
        // don't exist yet on a new device regardless of how much real
        // history the account already has in the cloud. initialSync's
        // sync-then-merge (Store.swift below) pushes local vehicles to
        // Supabase BEFORE pulling the cloud ones down, so this seed got
        // permanently written into the user's real cloud vehicle list on
        // every such sign-in — indistinguishable from a real vehicle, and
        // able to silently receive the very next trip if the user started
        // recording before noticing (round-3 UX review finding). There's
        // no reliable way to tell "new account" apart from "existing
        // account, new device" from local disk state alone, so the safe
        // fix is to never guess: VehiclesView's empty state already gives
        // a genuinely new user a clear, one-tap path to add their own
        // vehicle (with their own name/plate) instead of a throwaway
        // placeholder they'd need to rename anyway.

        // Lock any trips that have aged past the configured threshold.
        applyAutomaticLocks()
    }

    /// Marks any unlocked trip older than `settings.lockAfterDays` as locked.
    /// Locked trips become read-only for mileage / date / vehicle (enforced by
    /// the Postgres trigger as well). Purpose / notes / customer stay editable.
    /// Returns how many trips were newly locked, so callers like Settings'
    /// "Apply locks now" button can actually tell the user what happened —
    /// previously this compliance-relevant action gave zero outcome
    /// feedback (round-3 UX review finding).
    @discardableResult
    func applyAutomaticLocks() -> Int {
        let cutoff = Date().addingTimeInterval(-Double(settings.lockAfterDays) * 86_400)
        var lockedCount = 0
        for i in trips.indices where !trips[i].isLocked && trips[i].startedAt < cutoff {
            trips[i].isLocked = true
            trips[i].lockedAt = Date()
            lockedCount += 1
            push(trips[i])
        }
        if lockedCount > 0 { save() }
        return lockedCount
    }

    // MARK: - Lookups

    func vehicle(_ id: UUID) -> Vehicle? { vehicles.first { $0.id == id } }
    func vehicleName(_ id: UUID) -> String { vehicle(id)?.name ?? "Unknown vehicle" }

    /// Active vehicles only — used by pickers and report selectors so the
    /// user doesn't see archived ones in flows where they'd be confusing.
    var activeVehicles: [Vehicle] {
        vehicles.filter { $0.isActive }
    }

    var archivedVehicles: [Vehicle] {
        vehicles.filter { !$0.isActive }
    }

    /// Most recent trip date for a given vehicle, or nil if never used.
    func lastUsed(_ vehicleID: UUID) -> Date? {
        trips
            .filter { $0.vehicleID == vehicleID }
            .map { $0.startedAt }
            .max()
    }

    /// True when an active vehicle hasn't been used in `days` days AND
    /// has at least one historical trip (don't nag about brand-new cars).
    func shouldSuggestArchive(_ vehicle: Vehicle, days: Int = 90) -> Bool {
        guard vehicle.isActive, let last = lastUsed(vehicle.id) else { return false }
        return Date().timeIntervalSince(last) > Double(days) * 86_400
    }

    // MARK: - Trips

    /// Upserts by id rather than a bare append. A plain append could
    /// otherwise leave two entries sharing the same id — reachable via
    /// TripDetector's merge/reclaim mechanism: `resumeTrip` deliberately
    /// leaves a superseded trip's cloud row in place (see its own comment)
    /// rather than deleting it, so a sync cycle that pulls that stale row
    /// back into `trips` while the same id's trip is still active locally,
    /// followed by that trip eventually re-ending for real, would otherwise
    /// append a second entry instead of replacing the stale one — double-
    /// counting distance/reimbursement in every total, and making
    /// `deleteTrips`/`updateTrip` (both id-keyed) act on the wrong copy
    /// (round-4 adversarial review finding).
    func addTrip(_ trip: Trip) {
        trips.removeAll { $0.id == trip.id }
        trips.append(trip)
        save()
        push(trip)
    }

    /// Falls back to inserting (via `addTrip`) if the trip isn't found
    /// rather than silently no-op-ing. Reachable when a trip being edited
    /// gets merged/reclaimed back into an in-progress drive in the
    /// background while the edit sheet is still open — the id genuinely
    /// isn't in `trips` at save time, but the user's edit (e.g. tapping
    /// Save on the classify screen, which also sets `reviewedAt`) shouldn't
    /// silently vanish with a false "saved" confirmation (round-4
    /// adversarial review finding). If the trip later re-ends for real
    /// under the same id, `addTrip`'s upsert-by-id above correctly replaces
    /// this reinserted copy rather than duplicating it.
    func updateTrip(_ trip: Trip) {
        guard let idx = trips.firstIndex(where: { $0.id == trip.id }) else {
            addTrip(trip)
            return
        }
        // Merges only the fields TripEditor's UI actually lets the user
        // change onto the CURRENT live trip — never blindly overwrites the
        // whole struct with `trip` as passed in. `trip` can be a stale
        // SwiftUI @State snapshot: TripDetailView/TripEditor seed
        // `@State var trip` from their init argument, but a NavigationLink
        // destination's @State is only initialized the FIRST time that
        // screen is pushed — if the trip gets locked elsewhere (e.g.
        // Settings' "Apply locks now") while that detail screen is still
        // open on the nav stack, the open screen keeps showing/using the
        // pre-lock snapshot. Blindly overwriting on Save let that stale
        // screen silently re-unlock a trip (and could silently revert its
        // distance too), with recordAuditDiff unable to even see isLocked
        // change since it only diffs purpose/customerName/notes/type
        // (round-11 adversarial review finding).
        var merged = trips[idx]
        let previous = merged
        merged.purpose = trip.purpose
        merged.customerName = trip.customerName
        merged.notes = trip.notes
        // Prefer non-nil rather than blindly taking `trip`'s value: this
        // call site isn't only reached from a user-facing edit screen —
        // TripDetector.endTrip's own reverse-geocode Task fetches the live
        // trip, patches its addresses, and calls updateTrip too. If a
        // stale TripEditor @State (opened before some OTHER edit path —
        // e.g. a classify notification — already set reviewedAt) saved
        // afterward, blindly copying its nil would silently un-review the
        // trip again, and TripDetector.tryMergeWithRecentTrip requires
        // reviewedAt == nil to treat a trip as mergeable — re-opening an
        // already-classified trip to being silently merged with unrelated
        // later driving (round-13 adversarial review finding).
        merged.reviewedAt = trip.reviewedAt ?? previous.reviewedAt
        // Addresses are read-only display data in TripEditor (never a
        // TextField) and only ever meaningfully change via TripDetector's
        // async reverse-geocode backfill — which calls this same function.
        // Prefer non-empty rather than blindly taking `trip`'s value, for
        // the same reason as reviewedAt above: a stale TripEditor opened
        // BEFORE the geocode Task resolved still has empty addresses, and
        // saving it after that Task already patched in the real address
        // would silently stomp it back to blank (round-14 adversarial
        // review finding — the round-13 fix that made this field always-
        // copied to fix ONE caller's staleness broke the other direction
        // for a different caller).
        merged.startAddress = trip.startAddress.isEmpty ? previous.startAddress : trip.startAddress
        merged.endAddress = trip.endAddress.isEmpty ? previous.endAddress : trip.endAddress
        // Gate distance/type on the trip not having been re-ended under
        // the same id since this snapshot was taken, in addition to lock
        // status. TripDetector's brief-stop merge (tryMergeWithRecentTrip/
        // resumeTrip) removes an unreviewed, unlocked trip from
        // store.trips entirely and resurrects it as the active trip when
        // the vehicle starts moving again nearby — if the user has that
        // trip's (now stale) detail screen open when this happens, and the
        // resumed drive later ends for real with different final mileage,
        // `previous.isLocked` alone can't detect that the trip was
        // effectively replaced underneath the stale screen: the fresh,
        // correct trip is unlocked too. `endedAt` changes every time
        // endTrip runs — the same cheap version marker TripDetector's own
        // geocode-backfill Task already relies on for an identical
        // staleness check — so comparing it here closes the same class of
        // gap for distance/type (round-14 adversarial review finding).
        if !previous.isLocked && previous.endedAt == trip.endedAt {
            // `type` directly determines the reimbursement figure the lock
            // exists to freeze (Trip.reimbursement() pays a different rate —
            // or zero — per type) — it must be exactly as immutable as
            // distance once locked. Previously only distanceKm was gated
            // here, leaving the one field that actually controls the
            // reported €-amount silently changeable via this same stale-
            // snapshot path (round-12 adversarial review finding).
            merged.distanceKm = trip.distanceKm
            merged.type = trip.type
            // Lets TripEditor's Vehicle picker (round-16 addition) actually
            // take effect — auto-detection's Bluetooth-fallback path can
            // occasionally guess the wrong vehicle, and until now there was
            // no way to correct it. Same protection as type/distance:
            // immutable once locked, and gated on the same re-end check so
            // a stale screen can't silently misattribute a trip that was
            // resumed/re-ended in the meantime.
            merged.vehicleID = trip.vehicleID
        }
        trips[idx] = merged
        save()
        push(merged)

        // Every edit to a locked trip is recorded for the compliance audit log.
        if previous.isLocked { recordAuditDiff(from: previous, to: merged) }
    }

    private func recordAuditDiff(from old: Trip, to new: Trip) {
        var changes: [(field: String, old: String, new: String)] = []
        if old.purpose      != new.purpose      { changes.append(("purpose", old.purpose, new.purpose)) }
        if old.customerName != new.customerName { changes.append(("customer_name", old.customerName, new.customerName)) }
        if old.notes        != new.notes        { changes.append(("notes", old.notes, new.notes)) }
        if old.type         != new.type         { changes.append(("trip_type", old.type.rawValue, new.type.rawValue)) }

        guard !changes.isEmpty else { return }
        pendingAuditEntries += changes.map {
            PendingAuditEntry(tripID: new.id, field: $0.field, oldValue: $0.old, newValue: $0.new)
        }
        Task { await flushPendingAuditEntries() }
    }

    /// Pushes every queued audit entry, dropping each one from the queue
    /// only once its push actually succeeds. Called right after every edit
    /// to a locked trip, and again at the top of every `initialSync` — a
    /// push made while offline (or hitting any other transient failure)
    /// previously existed only for the lifetime of one fire-and-forget
    /// `Task { try? ... }`, with no way to ever reconstruct it afterward:
    /// the next edit diffs from the new state, not the one that entry would
    /// have recorded. This app already treats poor connectivity as routine
    /// enough to warrant retry/tombstone machinery for trip and vehicle
    /// deletes; the compliance audit trail — the one thing this codebase
    /// has previously shipped a dedicated migration to make actually work
    /// (migration-008's missing INSERT policy) — had no equivalent (round-10
    /// adversarial review finding). A push is a plain INSERT with no natural
    /// key to upsert against, so retrying an already-succeeded-but-
    /// response-lost push can create a duplicate row; accepted, since a
    /// duplicate audit entry is harmless for a tamper-evident trail but a
    /// silently missing one defeats its purpose.
    /// Guards against two overlapping flushes (one from `recordAuditDiff`'s
    /// own Task, one from `initialSync`) racing on the shared, UserDefaults-
    /// backed queue: `@MainActor` only serializes *synchronous* access, not
    /// across the `await` inside the loop below, so without this a second
    /// flush's read-modify-write of the whole array could silently clobber
    /// an entry a concurrent `recordAuditDiff` call appended in between
    /// (round-11 adversarial review finding).
    private var isFlushingAuditEntries = false

    func flushPendingAuditEntries() async {
        guard let supabase, !isFlushingAuditEntries else { return }
        isFlushingAuditEntries = true
        defer { isFlushingAuditEntries = false }
        // Removes each entry individually, right after ITS OWN push
        // succeeds, by re-reading the live queue at that moment rather than
        // computing a "remaining" list against a snapshot taken before any
        // awaits — the same class of lost-update bug the in-flight guard
        // above prevents between two calls, but reachable even within a
        // SINGLE call: a `recordAuditDiff` on the main actor can still run
        // between this loop's awaits and append a brand-new entry, which a
        // snapshot-based overwrite would have silently erased.
        for entry in pendingAuditEntries {
            do {
                try await supabase.pushAuditEntry(tripID: entry.tripID, field: entry.field,
                                                   oldValue: entry.oldValue, newValue: entry.newValue)
                pendingAuditEntries.removeAll { $0 == entry }
            } catch {
                // Leave it queued; the next flush (next edit or next sync) retries it.
            }
        }
        let stillQueued = pendingAuditEntries.count
        if stillQueued > 0 {
            detectionLog?.log("\(stillQueued) compliance audit-log entr\(stillQueued == 1 ? "y" : "ies") couldn't sync yet — will retry.",
                               level: .warning)
        }
    }

    private struct PendingAuditEntry: Codable, Equatable {
        let tripID: UUID
        let field: String
        let oldValue: String
        let newValue: String
    }

    /// Scoped per account like the delete tombstones — an entry queued
    /// under one account must never be pushed under a different one that
    /// later signs into the same device.
    private var pendingAuditEntries: [PendingAuditEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: tombstoneKey("MileLog.pendingAuditEntries")),
                  let decoded = try? JSONDecoder().decode([PendingAuditEntry].self, from: data) else { return [] }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: tombstoneKey("MileLog.pendingAuditEntries"))
        }
    }

    /// Refuses to delete a locked trip — `TripsListView` already disables
    /// the swipe gesture per-row via `.deleteDisabled(trip.isLocked)`, but
    /// this is the single choke point every deletion actually goes through,
    /// so it's the safe place to enforce it regardless of call site (round-7
    /// adversarial review finding: a locked trip is the exact record the
    /// locking feature exists to make tamper-evident for a tax audit).
    func deleteTrips(_ sectionTrips: [Trip], at offsets: IndexSet) {
        let ids = Set(offsets.map { sectionTrips[$0] }.filter { !$0.isLocked }.map(\.id))
        trips.removeAll { ids.contains($0.id) }
        deletedTripIDs.formUnion(ids)
        save()
        if let supabase {
            Task {
                for id in ids { try? await supabase.deleteTrip(id: id) }
            }
        }
    }

    /// Ids the user has deliberately deleted, persisted so `initialSync`'s
    /// merge-based pull (see its own doc comment) never re-adds one of them.
    /// Without this, a delete whose `supabase.deleteTrip`/`deleteVehicle`
    /// call silently failed (`try?`, offline/timeout — same connectivity
    /// pattern this app's comments cite throughout) leaves the cloud row in
    /// place; the very next sync's "add anything cloud-only" step would
    /// then resurrect it, since a deleted id is by definition no longer in
    /// the local array to be excluded by id (round-5 adversarial review
    /// finding). A tombstone is pruned once its retry in `initialSync`
    /// doesn't throw — but that alone isn't reliable proof of success
    /// across an account switch: RLS filters a DELETE to the calling
    /// account's own rows, so retrying account A's tombstone under a
    /// currently-signed-in account B affects zero rows and STILL doesn't
    /// throw, "confirming" and pruning a deletion B never actually
    /// performed on A's data (round-7 adversarial review finding). Scoped
    /// per account (by `lastSyncedUserID`) rather than globally, so B's
    /// sync can only ever see/prune B's own tombstones, never A's.
    private var deletedTripIDs: Set<UUID> {
        get { Self.readUUIDSet(key: tombstoneKey("MileLog.deletedTripIDs")) }
        set { Self.writeUUIDSet(newValue, key: tombstoneKey("MileLog.deletedTripIDs")) }
    }
    private var deletedVehicleIDs: Set<UUID> {
        get { Self.readUUIDSet(key: tombstoneKey("MileLog.deletedVehicleIDs")) }
        set { Self.writeUUIDSet(newValue, key: tombstoneKey("MileLog.deletedVehicleIDs")) }
    }
    private func tombstoneKey(_ base: String) -> String {
        guard let uid = lastSyncedUserID else { return base }
        return "\(base).\(uid.uuidString)"
    }
    private static func readUUIDSet(key: String) -> Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(strings.compactMap(UUID.init))
    }
    private static func writeUUIDSet(_ ids: Set<UUID>, key: String) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }

    /// Trips grouped by calendar month, newest first, with a per-month business total.
    var monthSections: [MonthSection] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: trips) { trip in
            cal.dateComponents([.year, .month], from: trip.startedAt)
        }
        let df = DateFormatter()
        df.dateFormat = "LLLL yyyy"

        return groups.keys
            .sorted { ($0.year ?? 0, $0.month ?? 0) > ($1.year ?? 0, $1.month ?? 0) }
            .map { comps in
                let items = (groups[comps] ?? []).sorted { $0.startedAt > $1.startedAt }
                let date = cal.date(from: comps) ?? Date()
                let businessKm = items
                    .filter { $0.type == .business }
                    .reduce(0) { $0 + $1.distanceKm }
                return MonthSection(
                    title: df.string(from: date),
                    trips: items,
                    summary: String(format: "%.0f km business", businessKm)
                )
            }
    }

    // MARK: - Vehicles

    func addVehicle(_ vehicle: Vehicle) {
        vehicles.append(vehicle)
        save()
        push(vehicle)
    }

    func updateVehicle(_ vehicle: Vehicle) {
        guard let idx = vehicles.firstIndex(where: { $0.id == vehicle.id }) else { return }
        // Merges only the fields VehicleEditView's UI actually lets the
        // user change onto the CURRENT live vehicle, the same reasoning as
        // updateTrip's merge (round-11 fix): a NavigationLink/sheet-pushed
        // screen's @State is seeded once and won't refresh just because
        // the store changes elsewhere while it stays open. `isActive` in
        // particular is never edited from this screen — it's flipped
        // externally by deleteVehicle()/restoreVehicle() — so a stale
        // snapshot must never be allowed to silently revert it (round-12
        // adversarial review finding: this was the one remaining place
        // still using the blind-overwrite pattern updateTrip was fixed
        // for).
        var merged = vehicles[idx]
        // `type`/`name`/`licensePlate`/`vehicleTypeDescription`/`seatCount`
        // are all printed straight from this live Vehicle into the
        // own-car PDF/CSV or the potni nalog header at Generate-tap time —
        // none of them snapshot per-trip. Changing any of them retroactively
        // reclassifies or relabels every trip ever driven in this vehicle,
        // including already-locked ones, bypassing the trip-level lock
        // entirely with zero audit trail (round-18 finding for `type`,
        // round-19 finding for the rest of these). Frozen the same way
        // distanceKm/type/vehicleID are frozen on a locked Trip: once ANY
        // trip referencing this vehicle is locked, none of these can
        // change — enforced here (not just in the UI's `.disabled`) so a
        // stale VehicleEditView screen can't bypass it either.
        // `defaultTripType`/Bluetooth pairing are exempt: neither is ever
        // printed on a report or affects an already-classified trip.
        if !trips.contains(where: { $0.vehicleID == vehicle.id && $0.isLocked }) {
            merged.name = vehicle.name
            merged.licensePlate = vehicle.licensePlate
            merged.type = vehicle.type
            merged.seatCount = vehicle.seatCount
            merged.vehicleTypeDescription = vehicle.vehicleTypeDescription
        }
        merged.defaultTripType = vehicle.defaultTripType
        merged.bluetoothName = vehicle.bluetoothName
        merged.bluetoothUID = vehicle.bluetoothUID
        vehicles[idx] = merged
        save()
        push(merged)
    }

    func deleteVehicle(at offsets: IndexSet) {
        for offset in offsets {
            let vehicle = vehicles[offset]
            // Route through deleteVehicle so we get the soft/hard split.
            _ = deleteVehicle(vehicle)
        }
    }

    /// Soft-deletes (archives) the vehicle if it has any trips, so historical
    /// references in `trips.vehicle_id` keep resolving. Hard-deletes a vehicle
    /// with no trips. Returns `.hard` or `.soft` so callers can show the
    /// right confirmation copy.
    enum DeletionMode { case soft, hard }

    @discardableResult
    func deleteVehicle(_ vehicle: Vehicle) -> DeletionMode {
        // A brand-new vehicle with zero COMPLETED trips can still be the
        // subject of an in-progress auto-detected one (its very first
        // drive) — `trips` alone wouldn't see that. Hard-deleting it out
        // from under that trip would leave it pointing at a vehicleID
        // nothing in store.vehicles resolves to once it ends (TripDetector
        // falls back to an ad-hoc, never-persisted "Unknown" vehicle in
        // that case — adversarial review finding).
        let hasTrips = trips.contains { $0.vehicleID == vehicle.id }
            || detector?.activeTrip?.vehicleID == vehicle.id

        if hasTrips {
            if let idx = vehicles.firstIndex(where: { $0.id == vehicle.id }) {
                vehicles[idx].isActive = false
                save()
                push(vehicles[idx])
            }
            return .soft
        } else {
            vehicles.removeAll { $0.id == vehicle.id }
            deletedVehicleIDs.insert(vehicle.id)
            save()
            if let supabase {
                Task { try? await supabase.deleteVehicle(id: vehicle.id) }
            }
            return .hard
        }
    }

    func restoreVehicle(_ vehicle: Vehicle) {
        if let idx = vehicles.firstIndex(where: { $0.id == vehicle.id }) {
            vehicles[idx].isActive = true
            save()
            push(vehicles[idx])
        }
    }

    // MARK: - Cloud sync

    /// Persists which account's data is currently held locally, so a
    /// sign-out followed by signing in as a genuinely DIFFERENT account can
    /// be told apart from re-signing into the same one or a first-ever
    /// sign-in. Without this, `initialSync` had no way to know the local
    /// `vehicles`/`trips`/`settings` it's about to push belong to a
    /// different, previous user — it would tag that stale data with the
    /// NEWLY signed-in user's id and insert it straight into their account
    /// (round-5 adversarial review finding — a confirmed cross-account data
    /// leak, reproducible via Settings → sign out → sign in as someone
    /// else, no relaunch needed).
    private var lastSyncedUserID: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "MileLog.lastSyncedUserID") else { return nil }
            return UUID(uuidString: s)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "MileLog.lastSyncedUserID") }
    }

    /// Called once after sign-in: push any local changes the cloud hasn't
    /// seen, then merge in anything the cloud has that's missing locally.
    ///
    /// Deliberately a MERGE, not the previous "replace local with whatever
    /// the cloud returns" — that was a real, confirmed data-loss risk
    /// (round-4 adversarial review finding): `pushTrip`/`pushVehicle` above
    /// are best-effort (`try?`, silently swallowed on failure, plausible
    /// given this app's own well-documented pattern of poor connectivity
    /// right around the app-relaunch events that also trigger this sync),
    /// so a trip that failed to push and then got replaced by a pull that
    /// never received it would be gone for good. Keeping every local
    /// trip/vehicle unconditionally and only ADDING cloud entries not
    /// already present locally (by id) trades away automatically adopting
    /// a same-id edit made on a different device — an acceptable cost for
    /// this single-device-in-practice app, against a guarantee of never
    /// silently destroying this device's own data.
    ///
    /// The currently-active auto-detected trip's id (if any) is excluded
    /// from what gets pulled in: `TripDetector.resumeTrip` deliberately
    /// leaves a superseded trip's cloud row in place across a merge/reclaim
    /// (see its own comment) rather than deleting it, trusting that trip's
    /// eventual real end to overwrite it — a stale cloud row under that
    /// same id re-entering `trips` as a "completed" ghost while the trip is
    /// still genuinely in progress would misrepresent it as done and,
    /// combined with a bare append, could double-count its distance
    /// (round-4 adversarial review finding; `addTrip`'s upsert-by-id above
    /// is the second half of closing this).
    ///
    /// Deleted-item tombstones (`deletedTripIDs`/`deletedVehicleIDs`) are
    /// also excluded from the merge, and their deletes are retried here —
    /// otherwise a delete whose cloud call silently failed would get
    /// resurrected by this same merge on the very next sync (round-5
    /// adversarial review finding).
    /// Guards against two `initialSync` calls overlapping — SwiftUI's
    /// `.task(id:)` cancellation (`RootView`'s trigger) is advisory only,
    /// and nothing in this function checked `Task.isCancelled`, so a rapid
    /// sign-out-then-sign-in-as-someone-else could start a second call
    /// while the first was still suspended on an earlier await, with both
    /// eventually resolving `currentUserId()` against whatever the shared
    /// session happens to be by then (round-7 adversarial review finding).
    /// Each call captures its own generation on entry and bails out the
    /// moment a newer call has superseded it, checked after every await
    /// that precedes a mutation.
    private var syncGeneration = 0

    func initialSync(via supabase: SupabaseService) async {
        self.supabase = supabase
        syncGeneration += 1
        let myGeneration = syncGeneration
        isSyncing = true
        // Only clear the flag if a NEWER call hasn't already superseded
        // this one — otherwise a stale call's own completion could flip
        // isSyncing back to false while a genuinely newer sync is still in
        // flight, the same class of race the syncGeneration guard already
        // exists to prevent for actual data mutations.
        defer { if myGeneration == syncGeneration { isSyncing = false } }

        guard let userID = try? await supabase.currentUserId(), myGeneration == syncGeneration else { return }
        if let previous = lastSyncedUserID, previous != userID {
            // A different account than whatever was last synced on this
            // device — the local state belongs to that previous account,
            // not this one. Discard any in-progress trip FIRST, before
            // wiping vehicles/trips/settings or letting anything below
            // push under the new identity — `disable()` alone was found to
            // let such a trip's data (and its own pushTrip call, tagged
            // with whatever identity happens to be authenticated by the
            // time it runs) escape into the new account, since it routes
            // through the normal endTrip()/addTrip()/push pipeline (round-6
            // adversarial review finding).
            detector?.discardActiveTripForAccountSwitch()
            vehicles = []
            trips = []
            settings = UserSettings()
            detector?.disable()
            // Purely local/on-device, but records raw GPS coordinates and
            // driving history for whichever account was signed in when
            // each entry was logged — must not carry over to a different
            // account on the same device (round-8 adversarial review
            // finding).
            detectionLog?.clear()
            save()
        }
        lastSyncedUserID = userID
        guard myGeneration == syncGeneration else { return }

        // Prune a tombstone the moment its delete call doesn't throw —
        // DELETE is idempotent (a row that's already gone, or never
        // existed, still doesn't throw), so a clean result IS confirmation
        // it's safe to stop retrying, rather than keeping every tombstone
        // forever (round-6 adversarial review finding: sync latency would
        // otherwise grow slowly but permanently over years of use).
        for id in deletedTripIDs {
            if (try? await supabase.deleteTrip(id: id)) != nil { deletedTripIDs.remove(id) }
        }
        for id in deletedVehicleIDs {
            if (try? await supabase.deleteVehicle(id: id)) != nil { deletedVehicleIDs.remove(id) }
        }
        await flushPendingAuditEntries()

        for vehicle in vehicles { try? await supabase.pushVehicle(vehicle) }
        for trip in trips       { try? await supabase.pushTrip(trip) }
        let settingsPushed = (try? await supabase.pushSettings(settings)) != nil
        guard myGeneration == syncGeneration else { return }

        // Track whether the DOWNLOAD half actually worked. Every call here
        // is `try?`-swallowed by design (a failed push is retried on the
        // next sync), but a failed PULL is different: it's the difference
        // between "you have no trips" and "we couldn't reach your trips,"
        // and the UI was showing the former for the latter — on a screen
        // telling a user with years of tax records to "record your first
        // trip" (round-5 UX review finding).
        // Tracked per collection, not as one shared flag: a trips pull that
        // failed while the vehicles pull SUCCEEDED (correctly returning
        // nothing for a new account) would otherwise replace the Vehicles
        // tab's onboarding "Add vehicle" call-to-action with a fabricated
        // "couldn't load your vehicles" error — steering a first-run user
        // away from the exact action they need (round-6 UX review finding).
        if let cloudVehicles = try? await supabase.pullVehicles() {
            let localIDs = Set(vehicles.map(\.id))
            vehicles += cloudVehicles.filter { !localIDs.contains($0.id) && !deletedVehicleIDs.contains($0.id) }
            vehiclesSyncFailed = false
        } else {
            vehiclesSyncFailed = true
        }
        if let cloudTrips = try? await supabase.pullTrips() {
            let localIDs = Set(trips.map(\.id))
            let activeID = detector?.activeTrip?.id
            trips += cloudTrips.filter {
                !localIDs.contains($0.id) && $0.id != activeID && !deletedTripIDs.contains($0.id)
            }
            tripsSyncFailed = false
        } else {
            tripsSyncFailed = true
        }
        // Unlike trips/vehicles, settings is a single object with no id to
        // merge by — so the only safe way to avoid clobbering a local edit
        // that failed to push is to skip adopting the cloud copy entirely
        // when the push didn't succeed. If push succeeded, the cloud
        // already reflects (at least) our own local settings, so pulling
        // it back is safe (round-5 adversarial review finding: pushing then
        // unconditionally pulling-and-replacing settings, unlike the
        // deliberately-merged trips/vehicles above, could silently revert a
        // local edit — e.g. a just-changed reimbursement rate or home
        // address — back to a stale cloud value whenever the push alone
        // happened to fail).
        if settingsPushed, let cloudSettings = try? await supabase.pullSettings() {
            settings = cloudSettings
        }
        save()
        // Re-arm auto-detect if this account's settings say it should be
        // running. Anything that calls `detector.disable()` mid-session —
        // sign-out, or the account-switch branch above — otherwise leaves
        // monitoring off until the next app relaunch, with both toggles
        // still rendering ON and every subsequent drive going unrecorded
        // (round-6 UX review finding). Placed after the settings pull so
        // it reflects the account that actually just signed in.
        detector?.resumeIfEnabled()
    }

    private func push(_ trip: Trip) {
        guard let supabase else { return }
        Task {
            do {
                try await supabase.pushTrip(trip)
            } catch {
                // Round 20 reacted to a rejected push by pulling the
                // authoritative row and overwriting local state if it
                // differed — but pushTrip throws identically for a genuine
                // DB-side rejection (trip_lock_guard) AND for a plain
                // transient network failure, and neither TripDTO nor
                // VehicleDTO carries any updated_at/version field to tell
                // the two apart. On an ordinary offline edit, the push
                // never reaches the server at all; if connectivity returns
                // a moment later, the pull would succeed and return the
                // STALE pre-edit cloud row, silently overwriting the
                // user's just-typed edit with older data — exactly the
                // silent-loss failure this mechanism was built to prevent,
                // just relocated onto ordinary connectivity hiccups
                // instead of the narrow multi-device lock race it was
                // designed for (round-21 adversarial review finding).
                // Without a reliable way to distinguish the two causes,
                // never guess: leave the local edit untouched and just log
                // it, so the failure is traceable instead of fully silent.
                // The existing per-sync retry loop (initialSync's `for
                // trip in trips { try? await supabase.pushTrip(trip) }`)
                // keeps retrying with the local edit intact regardless —
                // succeeding once connectivity returns, or failing (and
                // logging) again if it's a genuine, permanent rejection.
                detectionLog?.log("A trip failed to sync (offline, or rejected if locked/changed on another device) — will keep retrying.",
                                   level: .warning)
            }
        }
    }

    private func push(_ vehicle: Vehicle) {
        guard let supabase else { return }
        Task {
            do {
                try await supabase.pushVehicle(vehicle)
            } catch {
                // Same reasoning as push(_ trip:) above.
                detectionLog?.log("Vehicle '\(vehicle.name)' failed to sync (offline, or rejected if locked on another device) — will keep retrying.",
                                   level: .warning)
            }
        }
    }

    // MARK: - CSV export

    /// The count `exportCSV()` will actually write — kept in sync with its
    /// own filter so UI copy quoting a trip count doesn't overstate it
    /// (round-4 adversarial review finding).
    var exportableTripCount: Int { trips.filter { $0.distanceKm > 0 }.count }

    /// Writes a CSV of all trips to a temporary file and returns its URL (for ShareLink / email).
    func exportCSV() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var rows = ["Date,Vehicle,Type,Customer,Purpose,From,To,Distance (km),Reimbursement (EUR),Notes"]
        // Zero-distance trips are ignored in exports (auto-detector noise / aborted manual trips).
        for trip in trips.filter({ $0.distanceKm > 0 }).sorted(by: { $0.startedAt < $1.startedAt }) {
            // Only own-car trips are personally reimbursed at the mileage
            // rate — a company car's costs are covered directly by the
            // company (that's what the Potni Nalog logbook is for), exactly
            // as PDFReporter.ownCarCandidates already filters by vehicle
            // type before ever computing a reimbursement figure. This CSV
            // export had no such filter, so it printed a fabricated
            // €-reimbursement for company-car trips too (round-10
            // adversarial review finding).
            let isOwnCar = vehicle(trip.vehicleID)?.type == .own
            let cols = [
                df.string(from: trip.startedAt),
                vehicleName(trip.vehicleID),
                trip.type.label,
                trip.customerName,
                trip.purpose,
                trip.startAddress,
                trip.endAddress,
                String(format: "%.1f", trip.distanceKm),
                String(format: "%.2f", isOwnCar ? trip.reimbursement(
                    businessRate: settings.reimbursementRate,
                    commuteRate: settings.commuteRate
                ) : 0),
                trip.notes
            ]
            rows.append(cols.map(Self.csvEscape).joined(separator: ","))
        }

        let csv = rows.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MileLog-export.csv")
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: - Persistence

    /// `.atomic` on every write here matters more than it looks: a kill
    /// mid-write (this app has confirmed, field-documented cases of the
    /// process being terminated far more often than expected — see
    /// TripDetector's relaunch-recovery mechanism) can otherwise leave a
    /// truncated file. `load()` swallows a decode failure with `try?` and
    /// silently falls back to an empty array — the NEXT save() from any
    /// future trip/vehicle edit would then permanently overwrite the good
    /// data with that empty state. `.atomic` writes to a temp file and
    /// renames, so a kill mid-write leaves the OLD file intact instead of a
    /// corrupt new one (adversarial review finding).
    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(vehicles).write(to: vehiclesURL, options: .atomic)
        try? encoder.encode(trips).write(to: tripsURL, options: .atomic)
        try? encoder.encode(settings).write(to: settingsURL, options: .atomic)
        pushSettings()
    }

    private func pushSettings() {
        guard let supabase else { return }
        let snapshot = settings
        Task { try? await supabase.pushSettings(snapshot) }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let decoded = loadOrPreserveCorrupted([Vehicle].self, url: vehiclesURL, decoder: decoder) {
            vehicles = decoded
        }
        if let decoded = loadOrPreserveCorrupted([Trip].self, url: tripsURL, decoder: decoder) {
            trips = decoded
        }
        if let decoded = loadOrPreserveCorrupted(UserSettings.self, url: settingsURL, decoder: decoder) {
            settings = decoded
        }
    }

    /// Distinguishes "file doesn't exist" (fine — first launch, `vehicles`/
    /// `trips`/`settings` correctly stay at their empty/default values) from
    /// "file exists but failed to decode" (NOT fine as a silent no-op: the
    /// `@Published` property would be left at that same empty/default value
    /// with nothing to tell the two cases apart, and `save()` unconditionally
    /// rewrites ALL THREE files on every future mutation — so the very next
    /// trip added, vehicle edited, or setting changed anywhere in the app
    /// would permanently overwrite the corrupted-but-still-present file with
    /// that empty state, destroying whatever was recoverable in it). `.atomic`
    /// writes (already used everywhere in this file) rule out a kill-mid-
    /// write as the cause, but not a genuinely incompatible future schema
    /// change — this app has already been through several. On a genuine
    /// decode failure, the file is renamed aside instead of being left where
    /// the next save() would silently clobber it (round-2 adversarial review
    /// finding).
    private func loadOrPreserveCorrupted<T: Decodable>(_ type: T.Type, url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? decoder.decode(T.self, from: data) { return decoded }
        let backupURL = url.deletingPathExtension().appendingPathExtension("corrupted.json")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: url, to: backupURL)
        print("MileLog: \(url.lastPathComponent) exists but failed to decode — backed up to \(backupURL.lastPathComponent) instead of letting it be silently overwritten.")
        return nil
    }
}
