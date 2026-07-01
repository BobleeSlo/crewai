import Foundation

// MARK: - Enums

enum VehicleType: String, Codable, CaseIterable, Identifiable {
    case own
    case company

    var id: String { rawValue }

    /// Localized — looked up in Localizable.xcstrings at call time.
    var label: String {
        switch self {
        case .own:     return String(localized: "My car")
        case .company: return String(localized: "Company car")
        }
    }
}

enum TripType: String, Codable, CaseIterable, Identifiable {
    case business
    case commute
    case privateTrip = "private"   // `private` is a Swift keyword, so the case is renamed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .business:    return String(localized: "Business")
        case .commute:     return String(localized: "Commute")
        case .privateTrip: return String(localized: "Private")
        }
    }
}

/// GPS accuracy / power trade-off. Mapped to CLLocationManager settings by
/// `EnergyMode+CoreLocation.swift`.
enum EnergyMode: String, Codable, CaseIterable, Identifiable {
    case lowPower     = "low_power"
    case balanced     = "balanced"
    case highAccuracy = "high_accuracy"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lowPower:     return String(localized: "Low Power")
        case .balanced:     return String(localized: "Balanced")
        case .highAccuracy: return String(localized: "High Accuracy")
        }
    }

    var summary: String {
        switch self {
        case .lowPower:
            return String(localized: "≈100 m accuracy, max battery savings. Best for long highway drives.")
        case .balanced:
            return String(localized: "≈10 m accuracy. Recommended for most users — good track quality, moderate battery use.")
        case .highAccuracy:
            return String(localized: "Best available accuracy. For dense city driving where exact routes matter. Higher battery use.")
        }
    }
}

// MARK: - Vehicle

struct Vehicle: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var licensePlate: String
    var type: VehicleType

    // Phase 3a additions — defaults make older saved JSON forward-compatible.
    var bluetoothName: String = ""
    var bluetoothUID: String = ""
    var defaultTripType: TripType = .business

    /// Soft-delete flag. Inactive vehicles stay in the database so historical
    /// trips keep their reference, but are hidden from pickers and report
    /// selectors. Users can restore or permanently delete from the Vehicles list.
    var isActive: Bool = true

    init(
        id: UUID = UUID(),
        name: String,
        licensePlate: String,
        type: VehicleType,
        bluetoothName: String = "",
        bluetoothUID: String = "",
        defaultTripType: TripType = .business,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.licensePlate = licensePlate
        self.type = type
        self.bluetoothName = bluetoothName
        self.bluetoothUID = bluetoothUID
        self.defaultTripType = defaultTripType
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case id, name, licensePlate, type
        case bluetoothName, bluetoothUID, defaultTripType, isActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        licensePlate = try c.decode(String.self, forKey: .licensePlate)
        type = try c.decode(VehicleType.self, forKey: .type)
        bluetoothName = try c.decodeIfPresent(String.self, forKey: .bluetoothName) ?? ""
        bluetoothUID = try c.decodeIfPresent(String.self, forKey: .bluetoothUID) ?? ""
        defaultTripType = try c.decodeIfPresent(TripType.self, forKey: .defaultTripType) ?? .business
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

// MARK: - Trip (one logbook entry)

struct Trip: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var vehicleID: UUID
    var type: TripType
    var purpose: String
    var customerName: String
    var startedAt: Date
    var endedAt: Date
    var startAddress: String
    var endAddress: String
    /// End coordinates — used by `CustomerSuggester` to remember the location
    /// of customers and auto-fill the name when a future trip ends nearby.
    var endLat: Double? = nil
    var endLng: Double? = nil
    var distanceKm: Double
    var notes: String
    var isLocked: Bool
    var lockedAt: Date? = nil

    /// Reimbursement uses different rates per trip type. Private trips never reimburse.
    func reimbursement(businessRate: Double, commuteRate: Double) -> Double {
        switch type {
        case .business:    return distanceKm * businessRate
        case .commute:     return distanceKm * commuteRate
        case .privateTrip: return 0
        }
    }
}

// MARK: - Per-user settings (persisted locally + synced to Supabase)

struct UserSettings: Codable, Equatable {
    /// €/km for business trips with own car (e.g. visiting customers).
    var reimbursementRate: Double = 0.43
    /// €/km for commute trips with own car (Home ↔ Work). Typically lower.
    var commuteRate: Double = 0.18

    var homeAddress: String = ""
    var homeLat: Double? = nil
    var homeLng: Double? = nil

    var workAddress: String = ""
    var workLat: Double? = nil
    var workLng: Double? = nil

    var autoDetectEnabled: Bool = false
    var stationaryTimeoutMinutes: Int = 5
    var lockAfterDays: Int = 7
    var energyMode: EnergyMode = .balanced

    var hasHome: Bool { homeLat != nil && homeLng != nil }
    var hasWork: Bool { workLat != nil && workLng != nil }

    init(
        reimbursementRate: Double = 0.43,
        commuteRate: Double = 0.18,
        homeAddress: String = "",
        homeLat: Double? = nil,
        homeLng: Double? = nil,
        workAddress: String = "",
        workLat: Double? = nil,
        workLng: Double? = nil,
        autoDetectEnabled: Bool = false,
        stationaryTimeoutMinutes: Int = 5,
        lockAfterDays: Int = 7,
        energyMode: EnergyMode = .balanced
    ) {
        self.reimbursementRate = reimbursementRate
        self.commuteRate = commuteRate
        self.homeAddress = homeAddress
        self.homeLat = homeLat
        self.homeLng = homeLng
        self.workAddress = workAddress
        self.workLat = workLat
        self.workLng = workLng
        self.autoDetectEnabled = autoDetectEnabled
        self.stationaryTimeoutMinutes = stationaryTimeoutMinutes
        self.lockAfterDays = lockAfterDays
        self.energyMode = energyMode
    }

    enum CodingKeys: String, CodingKey {
        case reimbursementRate, commuteRate
        case homeAddress, homeLat, homeLng
        case workAddress, workLat, workLng
        case autoDetectEnabled, stationaryTimeoutMinutes, lockAfterDays, energyMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reimbursementRate = try c.decodeIfPresent(Double.self, forKey: .reimbursementRate) ?? 0.43
        commuteRate = try c.decodeIfPresent(Double.self, forKey: .commuteRate) ?? 0.18
        homeAddress = try c.decodeIfPresent(String.self, forKey: .homeAddress) ?? ""
        homeLat = try c.decodeIfPresent(Double.self, forKey: .homeLat)
        homeLng = try c.decodeIfPresent(Double.self, forKey: .homeLng)
        workAddress = try c.decodeIfPresent(String.self, forKey: .workAddress) ?? ""
        workLat = try c.decodeIfPresent(Double.self, forKey: .workLat)
        workLng = try c.decodeIfPresent(Double.self, forKey: .workLng)
        autoDetectEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoDetectEnabled) ?? false
        stationaryTimeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .stationaryTimeoutMinutes) ?? 5
        lockAfterDays = try c.decodeIfPresent(Int.self, forKey: .lockAfterDays) ?? 7
        energyMode = try c.decodeIfPresent(EnergyMode.self, forKey: .energyMode) ?? .balanced
    }
}

// MARK: - Receipts (Phase 4d)

enum ReceiptType: String, Codable, CaseIterable, Identifiable {
    case fuel
    case parking
    case toll
    case other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fuel:    return String(localized: "Fuel")
        case .parking: return String(localized: "Parking")
        case .toll:    return String(localized: "Toll")
        case .other:   return String(localized: "Other")
        }
    }
}

struct Receipt: Identifiable, Hashable {
    var id: UUID
    var type: ReceiptType
    var amountEur: Double?
    var vendor: String
    var photoPath: String     // Supabase Storage path (user_id/uuid.jpg)
    var date: Date?
    var notes: String

    init(
        id: UUID = UUID(),
        type: ReceiptType = .fuel,
        amountEur: Double? = nil,
        vendor: String = "",
        photoPath: String = "",
        date: Date? = nil,
        notes: String = ""
    ) {
        self.id = id; self.type = type; self.amountEur = amountEur
        self.vendor = vendor; self.photoPath = photoPath
        self.date = date; self.notes = notes
    }

    init?(from dto: ReceiptDTO) {
        guard let type = ReceiptType(rawValue: dto.receipt_type) else { return nil }
        self.init(
            id: dto.id,
            type: type,
            amountEur: dto.amount_eur,
            vendor: dto.vendor ?? "",
            photoPath: dto.photo_url ?? "",
            date: dto.receipt_date,
            notes: dto.notes ?? ""
        )
    }
}

// MARK: - Grouping helper for the trips list

struct MonthSection: Hashable {
    let title: String
    let trips: [Trip]
    let summary: String
}
