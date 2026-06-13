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

    // MARK: - Helpers

    private func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }
}
