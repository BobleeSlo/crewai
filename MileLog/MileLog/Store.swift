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
    @Published var reimbursementRate: Double = 0.43   // €/km — EDIT to the current rate, see README

    /// Set after the user signs in; when present, mutations are mirrored to Supabase.
    private weak var supabase: SupabaseService?

    private let vehiclesURL: URL
    private let tripsURL: URL
    private let settingsURL: URL

    private struct Settings: Codable { var reimbursementRate: Double }

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        vehiclesURL = dir.appendingPathComponent("vehicles.json")
        tripsURL    = dir.appendingPathComponent("trips.json")
        settingsURL = dir.appendingPathComponent("settings.json")
        load()

        // Seed a default vehicle on first launch so the user can record immediately.
        if vehicles.isEmpty {
            vehicles = [Vehicle(name: "My car", licensePlate: "", type: .own)]
            save()
        }
    }

    // MARK: - Lookups

    func vehicle(_ id: UUID) -> Vehicle? { vehicles.first { $0.id == id } }
    func vehicleName(_ id: UUID) -> String { vehicle(id)?.name ?? "Unknown vehicle" }

    // MARK: - Trips

    func addTrip(_ trip: Trip) {
        trips.append(trip)
        save()
        push(trip)
    }

    func updateTrip(_ trip: Trip) {
        guard let idx = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[idx] = trip
        save()
        push(trip)
    }

    func deleteTrips(_ sectionTrips: [Trip], at offsets: IndexSet) {
        let ids = Set(offsets.map { sectionTrips[$0].id })
        trips.removeAll { ids.contains($0.id) }
        save()
        if let supabase {
            Task {
                for id in ids { try? await supabase.deleteTrip(id: id) }
            }
        }
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
        vehicles[idx] = vehicle
        save()
        push(vehicle)
    }

    func deleteVehicle(at offsets: IndexSet) {
        let removed = offsets.map { vehicles[$0].id }
        vehicles.remove(atOffsets: offsets)
        save()
        if let supabase {
            Task {
                for id in removed { try? await supabase.deleteVehicle(id: id) }
            }
        }
    }

    // MARK: - Cloud sync

    /// Called once after sign-in: push any local changes the cloud hasn't seen,
    /// then replace local state with whatever the cloud has.
    func initialSync(via supabase: SupabaseService) async {
        self.supabase = supabase

        // Push local items first so they survive the pull-replace below.
        for vehicle in vehicles { try? await supabase.pushVehicle(vehicle) }
        for trip in trips       { try? await supabase.pushTrip(trip) }

        if let cloudVehicles = try? await supabase.pullVehicles(), !cloudVehicles.isEmpty {
            vehicles = cloudVehicles
        }
        if let cloudTrips = try? await supabase.pullTrips() {
            trips = cloudTrips
        }
        save()
    }

    private func push(_ trip: Trip) {
        guard let supabase else { return }
        Task { try? await supabase.pushTrip(trip) }
    }

    private func push(_ vehicle: Vehicle) {
        guard let supabase else { return }
        Task { try? await supabase.pushVehicle(vehicle) }
    }

    // MARK: - CSV export

    /// Writes a CSV of all trips to a temporary file and returns its URL (for ShareLink / email).
    func exportCSV() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var rows = ["Date,Vehicle,Type,Customer,Purpose,From,To,Distance (km),Reimbursement (EUR),Notes"]
        for trip in trips.sorted(by: { $0.startedAt < $1.startedAt }) {
            let cols = [
                df.string(from: trip.startedAt),
                vehicleName(trip.vehicleID),
                trip.type.label,
                trip.customerName,
                trip.purpose,
                trip.startAddress,
                trip.endAddress,
                String(format: "%.1f", trip.distanceKm),
                String(format: "%.2f", trip.reimbursement(rate: reimbursementRate)),
                trip.notes
            ]
            rows.append(cols.map(Self.csvEscape).joined(separator: ","))
        }

        let csv = rows.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MileLog-export.csv")
        do {
            try csv.data(using: .utf8)?.write(to: url)
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

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(vehicles).write(to: vehiclesURL)
        try? encoder.encode(trips).write(to: tripsURL)
        try? encoder.encode(Settings(reimbursementRate: reimbursementRate)).write(to: settingsURL)
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: vehiclesURL),
           let decoded = try? decoder.decode([Vehicle].self, from: data) {
            vehicles = decoded
        }
        if let data = try? Data(contentsOf: tripsURL),
           let decoded = try? decoder.decode([Trip].self, from: data) {
            trips = decoded
        }
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? decoder.decode(Settings.self, from: data) {
            reimbursementRate = decoded.reimbursementRate
        }
    }
}
