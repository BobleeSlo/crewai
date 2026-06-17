import Foundation

// Data transfer objects that match the Postgres tables in supabase/schema.sql
// (snake_case column names). They convert to/from the Swift domain models.

struct VehicleDTO: Codable {
    var id: UUID
    var user_id: UUID
    var name: String
    var license_plate: String
    var vehicle_type: String
    var bluetooth_name: String?
    var bluetooth_uid: String?
    var default_trip_type: String?

    init(from v: Vehicle, userId: UUID) {
        id = v.id
        user_id = userId
        name = v.name
        license_plate = v.licensePlate
        vehicle_type = v.type.rawValue
        bluetooth_name = v.bluetoothName.isEmpty ? nil : v.bluetoothName
        bluetooth_uid = v.bluetoothUID.isEmpty ? nil : v.bluetoothUID
        default_trip_type = v.defaultTripType.rawValue
    }

    func toVehicle() -> Vehicle {
        Vehicle(
            id: id,
            name: name,
            licensePlate: license_plate,
            type: VehicleType(rawValue: vehicle_type) ?? .own,
            bluetoothName: bluetooth_name ?? "",
            bluetoothUID: bluetooth_uid ?? "",
            defaultTripType: TripType(rawValue: default_trip_type ?? "") ?? .business
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
    var locked_at: Date?

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
        locked_at = t.lockedAt
    }

    func toTrip() -> Trip {
        var trip = Trip(
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
        trip.lockedAt = locked_at
        return trip
    }
}

struct TripAuditDTO: Codable {
    var trip_id: UUID
    var user_id: UUID
    var field_name: String
    var old_value: String
    var new_value: String
}

struct TripPointDTO: Codable {
    var trip_id: UUID
    var recorded_at: Date
    var lat: Double
    var lng: Double
    var speed_kmh: Float?
    var accuracy_m: Float?
}

struct ReceiptDTO: Codable {
    var id: UUID
    var user_id: UUID
    var trip_id: UUID?
    var receipt_type: String
    var amount_eur: Double?
    var vendor: String?
    var photo_url: String?
    var receipt_date: Date?
    var notes: String?
}

struct UserSettingsDTO: Codable {
    var user_id: UUID
    var reimbursement_rate: Double
    var commute_rate: Double?
    var home_address: String
    var home_lat: Double?
    var home_lng: Double?
    var work_address: String
    var work_lat: Double?
    var work_lng: Double?
    var auto_detect_enabled: Bool
    var stationary_timeout_minutes: Int
    var lock_after_days: Int

    init(from s: UserSettings, userId: UUID) {
        user_id = userId
        reimbursement_rate = s.reimbursementRate
        commute_rate = s.commuteRate
        home_address = s.homeAddress
        home_lat = s.homeLat
        home_lng = s.homeLng
        work_address = s.workAddress
        work_lat = s.workLat
        work_lng = s.workLng
        auto_detect_enabled = s.autoDetectEnabled
        stationary_timeout_minutes = s.stationaryTimeoutMinutes
        lock_after_days = s.lockAfterDays
    }

    func toSettings() -> UserSettings {
        UserSettings(
            reimbursementRate: reimbursement_rate,
            commuteRate: commute_rate ?? 0.18,
            homeAddress: home_address,
            homeLat: home_lat,
            homeLng: home_lng,
            workAddress: work_address,
            workLat: work_lat,
            workLng: work_lng,
            autoDetectEnabled: auto_detect_enabled,
            stationaryTimeoutMinutes: stationary_timeout_minutes,
            lockAfterDays: lock_after_days
        )
    }
}
