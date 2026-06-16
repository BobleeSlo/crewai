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

    let client: SupabaseClient

    init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
        Task { await refreshAuth() }
    }

    // MARK: - Auth

    func refreshAuth() async {
        do {
            let session = try await client.auth.session
            isAuthenticated = true
            userEmail = session.user.email
        } catch {
            isAuthenticated = false
            userEmail = nil
        }
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

    func signOut() async {
        isWorking = true
        defer { isWorking = false }
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
            .upload(path: path, file: data, options: .init(contentType: "image/jpeg", upsert: true))
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

    // MARK: - Helpers

    private func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }
}
