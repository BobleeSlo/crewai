import Foundation

// Data transfer objects that match the Postgres tables in supabase/schema.sql
// (snake_case column names). They convert to/from the Swift domain models.

struct VehicleDTO: Codable {
    var id: UUID
    var user_id: UUID
    var name: String
    var license_plate: String
    var vehicle_type: String

    init(from v: Vehicle, userId: UUID) {
        id = v.id
        user_id = userId
        name = v.name
        license_plate = v.licensePlate
        vehicle_type = v.type.rawValue
    }

    func toVehicle() -> Vehicle {
        Vehicle(
            id: id,
            name: name,
            licensePlate: license_plate,
            type: VehicleType(rawValue: vehicle_type) ?? .own
        )
    }
}

struct TripDTO: Codable {
    var id: UUID
    var user_id: UUID
    var vehicle_id: UUID
    var trip_type: String
    var purpose: String?
    var contact_met: String?           // re-used for customer/contact name
    var started_at: Date
    var ended_at: Date?
    var start_address: String?
    var end_address: String?
    var distance_km: Double
    var notes: String?
    var is_locked: Bool

    init(from t: Trip, userId: UUID) {
        id = t.id
        user_id = userId
        vehicle_id = t.vehicleID
        trip_type = t.type.rawValue
        purpose = t.purpose
        contact_met = t.customerName
        started_at = t.startedAt
        ended_at = t.endedAt
        start_address = t.startAddress
        end_address = t.endAddress
        distance_km = t.distanceKm
        notes = t.notes
        is_locked = t.isLocked
    }

    func toTrip() -> Trip {
        Trip(
            id: id,
            vehicleID: vehicle_id,
            type: TripType(rawValue: trip_type) ?? .business,
            purpose: purpose ?? "",
            customerName: contact_met ?? "",
            startedAt: started_at,
            endedAt: ended_at ?? started_at,
            startAddress: start_address ?? "",
            endAddress: end_address ?? "",
            distanceKm: distance_km,
            notes: notes ?? "",
            isLocked: is_locked
        )
    }
}
