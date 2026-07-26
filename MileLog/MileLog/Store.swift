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

    /// Convenience accessor kept for the existing UI/CSV code.
    var reimbursementRate: Double {
        get { settings.reimbursementRate }
        set { settings.reimbursementRate = newValue; save() }
    }

    /// Set after the user signs in; when present, mutations are mirrored to Supabase.
    private weak var supabase: SupabaseService?

    /// Read-only access for collaborators (TripDetector pushes GPS points + receipts).
    var supabaseService: SupabaseService? { supabase }

    private let vehiclesURL: URL
    private let tripsURL: URL
    private let settingsURL: URL

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

        // Lock any trips that have aged past the configured threshold.
        applyAutomaticLocks()
    }

    /// Marks any unlocked trip older than `settings.lockAfterDays` as locked.
    /// Locked trips become read-only for mileage / date / vehicle (enforced by
    /// the Postgres trigger as well). Purpose / notes / customer stay editable.
    func applyAutomaticLocks() {
        let cutoff = Date().addingTimeInterval(-Double(settings.lockAfterDays) * 86_400)
        var changed = false
        for i in trips.indices where !trips[i].isLocked && trips[i].startedAt < cutoff {
            trips[i].isLocked = true
            trips[i].lockedAt = Date()
            changed = true
            push(trips[i])
        }
        if changed { save() }
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

    func addTrip(_ trip: Trip) {
        trips.append(trip)
        save()
        push(trip)
    }

    func updateTrip(_ trip: Trip) {
        guard let idx = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        let previous = trips[idx]
        trips[idx] = trip
        save()
        push(trip)

        // Every edit to a locked trip is recorded for the compliance audit log.
        if previous.isLocked { recordAuditDiff(from: previous, to: trip) }
    }

    private func recordAuditDiff(from old: Trip, to new: Trip) {
        guard let supabase else { return }

        var changes: [(field: String, old: String, new: String)] = []
        if old.purpose      != new.purpose      { changes.append(("purpose", old.purpose, new.purpose)) }
        if old.customerName != new.customerName { changes.append(("customer_name", old.customerName, new.customerName)) }
        if old.notes        != new.notes        { changes.append(("notes", old.notes, new.notes)) }
        if old.type         != new.type         { changes.append(("trip_type", old.type.rawValue, new.type.rawValue)) }

        guard !changes.isEmpty else { return }
        let tripID = new.id
        Task {
            for change in changes {
                try? await supabase.pushAuditEntry(tripID: tripID, field: change.field,
                                                   oldValue: change.old, newValue: change.new)
            }
        }
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
        let hasTrips = trips.contains { $0.vehicleID == vehicle.id }

        if hasTrips {
            if let idx = vehicles.firstIndex(where: { $0.id == vehicle.id }) {
                vehicles[idx].isActive = false
                save()
                push(vehicles[idx])
            }
            return .soft
        } else {
            vehicles.removeAll { $0.id == vehicle.id }
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

    /// Called once after sign-in: push any local changes the cloud hasn't seen,
    /// then replace local state with whatever the cloud has.
    func initialSync(via supabase: SupabaseService) async {
        self.supabase = supabase

        // Push local items first so they survive the pull-replace below.
        for vehicle in vehicles { try? await supabase.pushVehicle(vehicle) }
        for trip in trips       { try? await supabase.pushTrip(trip) }
        try? await supabase.pushSettings(settings)

        if let cloudVehicles = try? await supabase.pullVehicles(), !cloudVehicles.isEmpty {
            vehicles = cloudVehicles
        }
        if let cloudTrips = try? await supabase.pullTrips() {
            trips = cloudTrips
        }
        if let cloudSettings = try? await supabase.pullSettings() {
            settings = cloudSettings
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
        // Zero-distance trips are ignored in exports (auto-detector noise / aborted manual trips).
        for trip in trips.filter({ $0.distanceKm > 0 }).sorted(by: { $0.startedAt < $1.startedAt }) {
            let cols = [
                df.string(from: trip.startedAt),
                vehicleName(trip.vehicleID),
                trip.type.label,
                trip.customerName,
                trip.purpose,
                trip.startAddress,
                trip.endAddress,
                String(format: "%.1f", trip.distanceKm),
                String(format: "%.2f", trip.reimbursement(
                    businessRate: settings.reimbursementRate,
                    commuteRate: settings.commuteRate
                )),
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
        if let data = try? Data(contentsOf: vehiclesURL),
           let decoded = try? decoder.decode([Vehicle].self, from: data) {
            vehicles = decoded
        }
        if let data = try? Data(contentsOf: tripsURL),
           let decoded = try? decoder.decode([Trip].self, from: data) {
            trips = decoded
        }
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? decoder.decode(UserSettings.self, from: data) {
            settings = decoded
        }
    }
}
