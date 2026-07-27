import Foundation
import Combine
import Supabase

/// Thin wrapper around the Supabase Swift SDK: auth state + simple CRUD
/// for vehicles and trips. UI state is published on the main actor.
@MainActor
final class SupabaseService: ObservableObject {

    @Published private(set) var isAuthenticated = false
    @Published private(set) var userEmail: String?
    @Published private(set) var isWorking = false
    /// False until the launch-time session restore has resolved one way or
    /// the other. `isAuthenticated` starts `false` and is only corrected by
    /// a detached Task in `init`, so without this third state every cold
    /// launch rendered the full email/password form for a frame before
    /// snapping to the tab bar — a recurring "did I get logged out?" jolt
    /// on an app people open in a car (round-7 UX review finding).
    @Published private(set) var didResolveInitialAuth = false

    /// Set by the app on launch (weak — these are the non-owning direction,
    /// same pattern as `Store.detector`). Lets `signOut()` discard any
    /// in-progress trip/manual recording the INSTANT sign-out happens,
    /// using the still-valid outgoing session, rather than waiting for
    /// `Store.initialSync` to react after a NEW sign-in later completes —
    /// that reactive-only approach left the entire signed-out/re-
    /// authenticating window (which can be arbitrarily long — however
    /// long the user takes on the auth screen) with nothing watching, so a
    /// trip that both started and ended purely via TripDetector's own 60s
    /// audit timer during that window still got pushed under whichever
    /// account ended up signed in when its fire-and-forget push actually
    /// ran (round-7 adversarial review finding — the round-6 fix only
    /// covered a trip still active at the moment `initialSync` itself ran).
    weak var detector: TripDetector?
    weak var manualLocation: LocationManager?

    let client: SupabaseClient

    init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
        Task { await refreshAuth() }
    }

    // MARK: - Auth

    /// Stops blocking the UI on a session restore that's taking too long.
    /// The restore itself keeps running — if it eventually succeeds,
    /// `refreshAuth`'s normal completion signs the user in — but the user
    /// gets an interactive sign-in screen in the meantime instead of an
    /// indefinite spinner (round-8 UX review finding).
    func abandonSessionRestore() {
        // Bump the generation so the still-suspended launch-time
        // `refreshAuth()` can't write auth state that has since moved on.
        authGeneration += 1
        didResolveInitialAuth = true
    }

    /// Incremented whenever the caller decides an in-flight auth resolution
    /// is no longer authoritative. Before `abandonSessionRestore()` existed,
    /// the launch restore was the only auth call in flight (everything else
    /// waited behind the launch spinner), so unconditional writes were safe.
    /// Abandoning deliberately removes that serialization — without this
    /// guard, a slow restore that finally timed out would sign out a user
    /// who had since signed in manually, and one that finally succeeded
    /// would yank a half-typed sign-in form out from under them (round-9 UX
    /// review finding).
    private var authGeneration = 0

    func refreshAuth() async {
        let generation = authGeneration
        do {
            let session = try await client.auth.session
            guard generation == authGeneration else { return }
            isAuthenticated = true
            userEmail = session.user.email
        } catch {
            guard generation == authGeneration else { return }
            isAuthenticated = false
            userEmail = nil
        }
        didResolveInitialAuth = true
    }

    func signUp(email: String, password: String) async throws {
        isWorking = true
        defer { isWorking = false }
        _ = try await client.auth.signUp(email: email, password: password)
        await refreshAuth()
    }

    func signIn(email: String, password: String) async throws {
        isWorking = true
        defer { isWorking = false }
        _ = try await client.auth.signIn(email: email, password: password)
        await refreshAuth()
    }

    /// Sends a password-reset email. Without this the app had no recovery
    /// path at all: a user who forgot their password — most likely exactly
    /// when the sign-in screen reappears, i.e. a new device or an expired
    /// session — was permanently locked out of their entire mileage
    /// history with no in-app way forward (round-5 UX review finding).
    func sendPasswordReset(email: String) async throws {
        isWorking = true
        defer { isWorking = false }
        // `redirectTo` is what makes the emailed link come back INTO the
        // app. Round 5 shipped this call without it, so the link landed on
        // the Supabase project's Site URL — outside the app, with nothing
        // able to complete the reset. The affordance existed and promised
        // recovery, but couldn't deliver it (round-6 UX review finding).
        try await client.auth.resetPasswordForEmail(
            email,
            redirectTo: SupabaseConfig.passwordResetRedirect
        )
    }

    /// Completes a password reset: exchanges the emailed recovery link for
    /// a session, so the subsequent password update is authorized.
    func handleRecoveryLink(_ url: URL) async throws {
        isWorking = true
        defer { isWorking = false }
        try await client.auth.session(from: url)
        await refreshAuth()
    }

    /// Sets a new password for the currently-recovered session.
    func updatePassword(_ newPassword: String) async throws {
        isWorking = true
        defer { isWorking = false }
        _ = try await client.auth.update(user: UserAttributes(password: newPassword))
        await refreshAuth()
    }

    func signOut() async {
        isWorking = true
        defer { isWorking = false }
        // Discard BEFORE tearing down the session — see the property doc
        // comments above for why waiting until a later sign-in's sync
        // reacts leaves the whole in-between window unguarded.
        detector?.discardActiveTripForAccountSwitch()
        manualLocation?.discardIfTracking()
        // Also stop WATCHING for new trips. Discarding the in-flight trip
        // alone left significant-location monitoring running under no
        // account: a signed-out user kept burning battery, kept getting
        // "Trip ended" notifications for drives recorded against nobody,
        // and those trips were then silently wiped if a different account
        // later signed in — with nothing on the auth screen hinting the
        // app was still tracking (round-5 UX review finding).
        detector?.disable()
        try? await client.auth.signOut()
        await refreshAuth()
    }

    // MARK: - Cloud CRUD

    func pullVehicles() async throws -> [Vehicle] {
        let dtos: [VehicleDTO] = try await client
            .from("vehicles").select().execute().value
        return dtos.map { $0.toVehicle() }
    }

    func pullTrips() async throws -> [Trip] {
        let dtos: [TripDTO] = try await client
            .from("trips").select().order("started_at", ascending: false).execute().value
        return dtos.map { $0.toTrip() }
    }

    func pushVehicle(_ vehicle: Vehicle) async throws {
        let dto = VehicleDTO(from: vehicle, userId: try await currentUserId())
        try await client.from("vehicles").upsert(dto).execute()
    }

    func pushTrip(_ trip: Trip) async throws {
        let dto = TripDTO(from: trip, userId: try await currentUserId())
        try await client.from("trips").upsert(dto).execute()
    }

    func deleteVehicle(id: UUID) async throws {
        try await client.from("vehicles").delete().eq("id", value: id).execute()
    }

    func deleteTrip(id: UUID) async throws {
        try await client.from("trips").delete().eq("id", value: id).execute()
    }

    // MARK: - User settings

    func pushSettings(_ settings: UserSettings) async throws {
        let dto = UserSettingsDTO(from: settings, userId: try await currentUserId())
        try await client.from("user_settings").upsert(dto).execute()
    }

    func pullSettings() async throws -> UserSettings? {
        let dtos: [UserSettingsDTO] = try await client
            .from("user_settings").select().limit(1).execute().value
        return dtos.first?.toSettings()
    }

    // MARK: - Audit log (Phase 4b)

    func pushAuditEntry(tripID: UUID, field: String, oldValue: String, newValue: String) async throws {
        let dto = TripAuditDTO(
            trip_id: tripID,
            user_id: try await currentUserId(),
            field_name: field,
            old_value: oldValue,
            new_value: newValue
        )
        try await client.from("trip_audit_log").insert(dto).execute()
    }

    // MARK: - GPS track (Phase 4c)

    func pushTripPoints(_ points: [TripPointDTO]) async throws {
        guard !points.isEmpty else { return }
        try await client.from("trip_points").insert(points).execute()
    }

    func pullTripPoints(for tripID: UUID) async throws -> [TripPointDTO] {
        try await client.from("trip_points")
            .select()
            .eq("trip_id", value: tripID)
            .order("recorded_at", ascending: true)
            .execute()
            .value
    }

    // MARK: - Receipts (Phase 4d)

    func uploadReceiptPhoto(_ data: Data, fileName: String) async throws -> String {
        let path = "\(try await currentUserId().uuidString)/\(fileName)"
        try await client.storage
            .from("receipts")
            .upload(path, data: data, options: .init(contentType: "image/jpeg", upsert: true))
        // Public URL (the bucket can be private; we generate a signed URL on demand instead, but
        // for V1 we store the path and rely on the client to fetch via the SDK).
        return path
    }

    func pushReceipt(_ receipt: Receipt, tripID: UUID?) async throws {
        let dto = ReceiptDTO(
            id: receipt.id,
            user_id: try await currentUserId(),
            trip_id: tripID,
            receipt_type: receipt.type.rawValue,
            amount_eur: receipt.amountEur,
            vendor: receipt.vendor.isEmpty ? nil : receipt.vendor,
            photo_url: receipt.photoPath.isEmpty ? nil : receipt.photoPath,
            receipt_date: receipt.date,
            notes: receipt.notes.isEmpty ? nil : receipt.notes
        )
        try await client.from("receipts").upsert(dto).execute()
    }

    func pullReceipts(for tripID: UUID) async throws -> [Receipt] {
        let dtos: [ReceiptDTO] = try await client.from("receipts")
            .select()
            .eq("trip_id", value: tripID)
            .execute()
            .value
        return dtos.compactMap { Receipt(from: $0) }
    }

    func downloadReceiptPhoto(path: String) async throws -> Data {
        try await client.storage.from("receipts").download(path: path)
    }

    /// Removes the receipt row and its stored photo. Without this,
    /// `ReceiptsSection`'s swipe-to-delete only mutated its local array —
    /// and since `TripEditor` re-pulls receipts every time the trip is
    /// opened, the "deleted" receipt simply reappeared and stayed attached
    /// to the record (round-5 UX review finding). The photo delete is
    /// best-effort: an orphaned blob is a storage-cost annoyance, whereas
    /// a row that won't stay deleted is a visible correctness problem, so
    /// the row delete is the one allowed to throw.
    func deleteReceipt(_ receipt: Receipt) async throws {
        try await client.from("receipts")
            .delete()
            .eq("id", value: receipt.id)
            .execute()
        if !receipt.photoPath.isEmpty {
            // `remove` returns the deleted objects; discarded on purpose.
            // The row is already gone, so a failed blob delete leaves an
            // orphaned file rather than a broken receipt — not worth
            // failing the call for.
            _ = try? await client.storage.from("receipts")
                .remove(paths: [receipt.photoPath])
        }
    }

    // MARK: - Helpers

    /// Not private: `Store.initialSync` needs this to detect a sign-out
    /// followed by signing in as a genuinely different account, so it can
    /// wipe stale local data before that data gets pushed (tagged with the
    /// NEW user's id) into the new account's own rows (round-5 adversarial
    /// review finding — a confirmed cross-account data leak).
    func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }
}
