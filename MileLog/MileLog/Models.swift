import Foundation

// MARK: - Enums

enum VehicleType: String, Codable, CaseIterable, Identifiable {
    case own
    case company

    var id: String { rawValue }

    var label: String {
        switch self {
        case .own:     return "My car"
        case .company: return "Company car"
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
        case .business:    return "Business"
        case .commute:     return "Commute"
        case .privateTrip: return "Private"
        }
    }
}

// MARK: - Vehicle

struct Vehicle: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var licensePlate: String
    var type: VehicleType
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
    var distanceKm: Double
    var notes: String
    var isLocked: Bool

    /// Tax-free reimbursement only applies to business kilometres.
    func reimbursement(rate: Double) -> Double {
        type == .business ? distanceKm * rate : 0
    }
}

// MARK: - Grouping helper for the trips list

struct MonthSection: Hashable {
    let title: String
    let trips: [Trip]
    let summary: String
}
