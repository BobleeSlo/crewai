import SwiftUI
import CoreLocation
import UIKit

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var detector: TripDetector
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var appLock: AppLock
    @State private var exportURL: URL?
    @State private var lockResultMessage: String?

    @State private var homeInput = ""
    @State private var workInput = ""
    @State private var geocodeStatus: String?
    @State private var isGeocoding = false

    // Monthly own-car PDF export state (PDF result lives in ReportSelectionView)
    @State private var pdfYear: Int = Calendar.current.component(.year, from: Date())
    @State private var pdfMonth: Int = Calendar.current.component(.month, from: Date())

    // Company car logbook PDF state
    @State private var logbookVehicleID: UUID?
    @State private var logbookYear: Int = Calendar.current.component(.year, from: Date())
    @State private var logbookMonth: Int = Calendar.current.component(.month, from: Date())

    private enum Field: Hashable { case rate, commuteRate, home, work }
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {

                // MARK: Reimbursement
                Section {
                    HStack {
                        Text("Business rate")
                        Spacer()
                        TextField("0.43", value: $store.settings.reimbursementRate, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .rate)
                            .frame(maxWidth: 80)
                        Text("€/km").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Commute rate")
                        Spacer()
                        TextField("0.18", value: $store.settings.commuteRate, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .commuteRate)
                            .frame(maxWidth: 80)
                        Text("€/km").foregroundColor(.secondary)
                    }
                    Text("Business rate applies to customer visits with your own car. Commute rate applies to Home ↔ Work trips. Private trips and company-car trips are excluded from the monthly own-car report.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    SectionHeaderLabel(title: "Reimbursement", systemImage: "eurosign.circle")
                }

                // MARK: Auto-detect
                Section {
                    Toggle(isOn: Binding(
                        get: { store.settings.autoDetectEnabled },
                        set: { detector.setAutoDetect($0) }
                    )) {
                        Label("Detect trips automatically", systemImage: "location.fill")
                    }
                    Text(autoDetectHint)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    PrettyStepper(
                        value: $store.settings.stationaryTimeoutMinutes,
                        range: 2...20,
                        label: "End trip after",
                        unit: "min stationary"
                    )

                    if store.settings.autoDetectEnabled && detector.permission != .authorizedAlways {
                        // Once permission is actually denied, re-requesting
                        // it (`detector.requestEnable()`) is a guaranteed
                        // no-op — iOS never re-shows the system prompt,
                        // `requestEnable()` just logs a warning nobody but
                        // this app's own debug screen ever sees. The button
                        // looked identically actionable in every state, but
                        // silently did nothing in the one state a user is
                        // most likely to be stuck in (round-1 UX review
                        // finding).
                        if detector.permission == .denied || detector.permission == .restricted {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label("Open Settings", systemImage: "gear")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                Task { await detector.requestEnable() }
                            } label: {
                                Label("Grant location permission", systemImage: "checkmark.shield")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    NavigationLink {
                        DetectionLogView()
                    } label: {
                        Label("Detection log", systemImage: "list.bullet.rectangle.portrait")
                    }
                } header: {
                    SectionHeaderLabel(title: "Auto-detect trips", systemImage: "dot.radiowaves.left.and.right")
                }

                // MARK: Energy mode
                Section {
                    Picker(selection: $store.settings.energyMode) {
                        ForEach(EnergyMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        Label("Mode", systemImage: "bolt.fill")
                    }
                    .pickerStyle(.segmented)

                    Text(store.settings.energyMode.summary)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    SectionHeaderLabel(title: "Energy mode", systemImage: "battery.75")
                } footer: {
                    // This used to say "changes take effect on the next
                    // trip start" — factually wrong. LocationManager.apply
                    // (energyMode:) mutates the live CLLocationManager
                    // immediately, and TripDetector re-reads the mode's
                    // GPS-accuracy threshold live inside its per-fix
                    // callbacks — switching modes mid-drive immediately
                    // changes which GPS fixes get accepted into whatever
                    // trip is currently recording, the opposite of what
                    // this told the user (round-3 UX review finding).
                    Text("Switch presets any time — changes apply immediately, even to a trip already in progress.")
                        .font(.caption)
                }

                // MARK: Compliance & locking
                Section {
                    PrettyStepper(
                        value: $store.settings.lockAfterDays,
                        range: 1...90,
                        label: "Lock trips after",
                        unit: "days"
                    )
                    Text("Once locked, a trip's mileage / date / vehicle become immutable. Edits to purpose, customer, and notes are still allowed but recorded in the audit log.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button {
                        // A compliance-relevant action that previously
                        // acted with zero outcome feedback — the button
                        // gave no indication of how many trips (if any)
                        // were actually locked (round-3 UX review finding).
                        let count = store.applyAutomaticLocks()
                        lockResultMessage = count == 0
                            ? "No trips needed locking."
                            : "Locked \(count) trip\(count == 1 ? "" : "s")."
                    } label: {
                        Label("Apply locks now", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    if let lockResultMessage {
                        Text(lockResultMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    SectionHeaderLabel(title: "Compliance & locking", systemImage: "lock.shield")
                }

                // MARK: Home & Work
                Section {
                    addressField(
                        placeholder: "Home address",
                        text: $homeInput,
                        lat: store.settings.homeLat,
                        lng: store.settings.homeLng,
                        focus: .home
                    )

                    addressField(
                        placeholder: "Work address",
                        text: $workInput,
                        lat: store.settings.workLat,
                        lng: store.settings.workLng,
                        focus: .work
                    )

                    Button {
                        Task { await geocodeAddresses() }
                    } label: {
                        Label(isGeocoding ? "Resolving…" : "Resolve addresses",
                              systemImage: "mappin.and.ellipse")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGeocoding || (homeInput.isEmpty && workInput.isEmpty))

                    if let geocodeStatus {
                        Text(geocodeStatus)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Text("Used to recognize commute trips (Home → Work mornings, Work → Home evenings).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    SectionHeaderLabel(title: "Home & Work", systemImage: "house")
                }

                // MARK: Monthly own-car PDF (for bookkeeping reimbursement)
                Section {
                    Picker("Month", selection: $pdfMonth) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthLabel(m)).tag(m)
                        }
                    }
                    Picker("Year", selection: $pdfYear) {
                        ForEach(yearRange, id: \.self) { y in
                            Text(String(y)).tag(y)
                        }
                    }

                    NavigationLink {
                        ownCarSelection
                    } label: {
                        Label("Review trips and generate", systemImage: "list.bullet.rectangle.portrait")
                            .frame(maxWidth: .infinity)
                    }

                    Text("Own-car business + commute trips only. Private trips and company-car trips are excluded. On the next screen you can check / uncheck individual trips before generating the PDF for your accountant.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    SectionHeaderLabel(title: "Own-car monthly report", systemImage: "doc.text")
                }

                // MARK: Company car logbook (potni nalog)
                if !companyVehicles.isEmpty {
                    Section {
                        TextField("Company name", text: $store.settings.companyName)
                        TextField("Company address", text: $store.settings.companyAddress)
                        TextField("Company location (mesto)", text: $store.settings.companyLocation)
                        TextField("Driver name", text: $store.settings.driverName)
                        // Every sibling field above has an English gloss;
                        // these two didn't, breaking the pattern the rest
                        // of the section establishes and leaving anyone
                        // unfamiliar with these specific Slovenian
                        // administrative terms with no in-app clue what to
                        // type (round-2 UX review finding).
                        TextField("Koristnik po nalogu (beneficiary)", text: $store.settings.tripBeneficiary)
                        TextField("Na relaciji (area/route)", text: $store.settings.tripArea)

                        Text("Printed in the potni nalog header. Per-vehicle seat count and vehicle type are set on the vehicle itself.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } header: {
                        SectionHeaderLabel(title: "Potni nalog details", systemImage: "building.2")
                    }

                    Section {
                        Picker("Vehicle", selection: $logbookVehicleID) {
                            ForEach(companyVehicles) { v in
                                Text("\(v.name) \(v.licensePlate.isEmpty ? "" : "· \(v.licensePlate)")")
                                    .tag(Optional(v.id))
                            }
                        }
                        Picker("Month", selection: $logbookMonth) {
                            ForEach(1...12, id: \.self) { m in
                                Text(monthLabel(m)).tag(m)
                            }
                        }
                        Picker("Year", selection: $logbookYear) {
                            ForEach(yearRange, id: \.self) { y in
                                Text(String(y)).tag(y)
                            }
                        }
                        NavigationLink {
                            logbookSelection
                        } label: {
                            Label("Review trips and generate", systemImage: "list.bullet.rectangle.portrait")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(logbookVehicleID == nil)

                        Text("Slovenian potni nalog layout: date / departure / arrival / from / to / purpose / km. Odometer-start, odometer-end and signature columns are left blank so you can fill them by hand. Review and select trips on the next screen.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } header: {
                        SectionHeaderLabel(title: "Company car · potni nalog", systemImage: "book")
                    }
                }

                // MARK: CSV export
                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export \(store.exportableTripCount) trips as CSV",
                                  systemImage: "tablecells")
                        }
                    } else {
                        Text("No trips to export yet.")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    SectionHeaderLabel(title: "All trips (CSV)", systemImage: "tablecells")
                }

                // MARK: Security (biometric lock)
                Section {
                    if BiometricAuth.isAvailable {
                        Toggle(isOn: Binding(
                            get: { appLock.enabled },
                            set: { wantOn in
                                Task {
                                    if wantOn {
                                        await appLock.enable()   // only enables on successful auth
                                    } else {
                                        appLock.disable()
                                    }
                                }
                            }
                        )) {
                            Label("Require \(BiometricAuth.available.label)",
                                  systemImage: BiometricAuth.available.systemImage)
                        }
                        Text("When on, MileLog asks for \(BiometricAuth.available.label) each time you open it or return from the background.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Label("Face ID / Touch ID not available", systemImage: "lock.slash")
                            .foregroundColor(.secondary)
                        Text("Set up Face ID or Touch ID in iOS Settings to enable app lock.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    SectionHeaderLabel(title: "Security", systemImage: "lock.shield")
                }

                // MARK: Account
                Section {
                    LabeledContent("Signed in as", value: supabase.userEmail ?? "—")
                    Button(role: .destructive) {
                        // Re-lock immediately rather than waiting for the
                        // next .background transition — otherwise signing
                        // out and back in (or as a different account)
                        // without ever backgrounding the app skips the
                        // Face ID/Touch ID prompt this section promises
                        // "each time you open it" (round-9 adversarial
                        // review finding).
                        appLock.lock()
                        Task { await supabase.signOut() }
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } header: {
                    SectionHeaderLabel(title: "Account", systemImage: "person.crop.circle")
                }

                Section {
                    LabeledContent("App", value: "MileLog")
                    LabeledContent("Sync", value: "Supabase cloud")
                } header: {
                    SectionHeaderLabel(title: "About", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
            .keyboardDoneToolbar()
            .onAppear {
                refreshExport()
                homeInput = store.settings.homeAddress
                workInput = store.settings.workAddress
            }
            .onChange(of: store.trips.count) { refreshExport() }
            .onChange(of: store.settings.reimbursementRate) {
                store.save()
                refreshExport()
            }
            .onChange(of: store.settings.commuteRate) {
                store.save()
                refreshExport()
            }
            // Auto-detect enable/disable is handled by detector.setAutoDetect
            // via the Toggle binding (shared with the Record-screen toggle),
            // so no onChange handler is needed here.
            .onChange(of: store.settings.stationaryTimeoutMinutes) { store.save() }
            .onChange(of: store.settings.lockAfterDays) { store.save() }
            .onChange(of: store.settings.companyName) { store.save() }
            .onChange(of: store.settings.companyAddress) { store.save() }
            .onChange(of: store.settings.companyLocation) { store.save() }
            .onChange(of: store.settings.driverName) { store.save() }
            .onChange(of: store.settings.tripBeneficiary) { store.save() }
            .onChange(of: store.settings.tripArea) { store.save() }
            .onChange(of: store.settings.energyMode) { _, newMode in
                store.save()
                location.apply(energyMode: newMode)
                // TripDetector picks up the new mode automatically on next trip start.
            }
        }
    }

    // MARK: - Address field helper

    @ViewBuilder
    private func addressField(
        placeholder: String,
        text: Binding<String>,
        lat: Double?,
        lng: Double?,
        focus: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($focusedField, equals: focus)
                .onSubmit {
                    Task { await geocodeAddresses() }
                }

            if let lat, let lng {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption2)
                    Text(String(format: "%.4f, %.4f", lat, lng))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var autoDetectHint: String {
        if !store.settings.autoDetectEnabled {
            return "When enabled, the app starts trips automatically when you start driving and ends them when you stop."
        }
        switch detector.permission {
        case .authorizedAlways:
            return detector.isEnabled
                ? "Monitoring is active. Pair your cars under Vehicles to identify which car you're driving."
                : "Permission granted but monitoring is off — toggle off and on to restart."
        case .authorizedWhenInUse:
            return "Need 'Always' location permission for background detection. Tap the button below to upgrade."
        case .notDetermined:
            return "Tap the button below to grant location permission."
        case .denied, .restricted:
            return "Location permission denied. Enable 'Always' for MileLog in iOS Settings → Privacy."
        @unknown default:
            return ""
        }
    }

    private func refreshExport() {
        exportURL = store.trips.isEmpty ? nil : store.exportCSV()
    }

    private func monthLabel(_ month: Int) -> String {
        let df = DateFormatter()
        return df.monthSymbols[month - 1]
    }

    /// Years that have at least one trip plus the current year.
    private var yearRange: [Int] {
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        var years = Set<Int>([thisYear])
        for trip in store.trips {
            years.insert(cal.component(.year, from: trip.startedAt))
        }
        return years.sorted(by: >)
    }

    /// Vehicles eligible for the company-car logbook export.
    /// Archived vehicles are hidden — the user has to restore one first
    /// before they can run a logbook against it.
    private var companyVehicles: [Vehicle] {
        store.activeVehicles.filter { $0.type == .company }
    }

    // MARK: - Selection destinations

    @ViewBuilder
    private var ownCarSelection: some View {
        let candidates = PDFReporter.ownCarCandidates(
            trips: store.trips,
            vehicleLookup: { store.vehicle($0) },
            year: pdfYear, month: pdfMonth
        )
        let businessRate = store.settings.reimbursementRate
        let commuteRate = store.settings.commuteRate
        let year = pdfYear, month = pdfMonth

        ReportSelectionView(
            title: "\(monthLabel(month)) \(String(year))",
            candidateTrips: candidates,
            formatRow: { trip in AnyView(ownCarRow(trip: trip)) },
            generate: { chosen in
                PDFReporter.generateMonthlyOwnCar(
                    trips: chosen,
                    vehicleLookup: { store.vehicle($0) },
                    businessRate: businessRate,
                    commuteRate: commuteRate,
                    year: year, month: month
                )
            }
        )
    }

    @ViewBuilder
    private var logbookSelection: some View {
        if let id = logbookVehicleID, let vehicle = store.vehicle(id) {
            let candidates = PDFReporter.companyLogbookCandidates(
                trips: store.trips,
                vehicle: vehicle,
                year: logbookYear, month: logbookMonth
            )
            let year = logbookYear, month = logbookMonth
            let captured = vehicle

            ReportSelectionView(
                title: "\(vehicle.name) · \(monthLabel(month)) \(String(year))",
                candidateTrips: candidates,
                // The potni nalog is an official business-travel-order
                // document (every generated page hardcodes "Vrsta prevoza:
                // SLUŽBENA POT"). Unlike the own-car report, this report's
                // candidates intentionally include private trips too — so a
                // full logbook can reconcile total company-car mileage — but
                // they must never be silently pre-checked into an official
                // business record. Default-select only business/commute;
                // private trips stay visible (badged, see logbookRow) and
                // selectable, requiring a conscious opt-in (round-9
                // adversarial review finding).
                defaultSelected: candidates.filter { $0.type != .privateTrip },
                formatRow: { trip in AnyView(logbookRow(trip: trip)) },
                generate: { chosen in
                    PDFReporter.generateCompanyCarLogbook(
                        trips: chosen,
                        vehicle: captured,
                        settings: store.settings,
                        year: year, month: month
                    )
                }
            )
        }
    }

    /// Three-column row used in both selection screens: [date + type chip] |
    /// customer-or-purpose (flexible width, prominent) | km (right-aligned).
    @ViewBuilder
    private func ownCarRow(trip: Trip) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.medium))
                Text(trip.type.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(typeBadgeColor(trip.type).opacity(0.2))
                    .foregroundColor(typeBadgeColor(trip.type))
                    .clipShape(Capsule())
            }
            .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(customerOrPurpose(trip))
                    .font(.subheadline)
                    .foregroundColor(hasCustomerOrPurpose(trip) ? .primary : .secondary)
                    .lineLimit(2)
                if !trip.customerName.isEmpty && !trip.purpose.isEmpty {
                    Text(trip.purpose)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%.1f km", trip.distanceKm))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func logbookRow(trip: Trip) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.medium))
                Text(trip.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                // Unlike ownCarRow, this list previously showed no type
                // indicator at all, so a private trip riding along in a
                // company car's official travel-order document looked
                // identical to a business one (round-9 adversarial review
                // finding).
                Text(trip.type.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(typeBadgeColor(trip.type).opacity(0.2))
                    .foregroundColor(typeBadgeColor(trip.type))
                    .clipShape(Capsule())
            }
            .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(customerOrPurpose(trip))
                    .font(.subheadline)
                    .foregroundColor(hasCustomerOrPurpose(trip) ? .primary : .secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%.1f km", trip.distanceKm))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private func customerOrPurpose(_ trip: Trip) -> String {
        if !trip.customerName.isEmpty { return trip.customerName }
        if !trip.purpose.isEmpty      { return trip.purpose }
        return "—"
    }

    private func hasCustomerOrPurpose(_ trip: Trip) -> Bool {
        !trip.customerName.isEmpty || !trip.purpose.isEmpty
    }

    private func typeBadgeColor(_ type: TripType) -> Color {
        switch type {
        case .business:    return .blue
        case .commute:     return .orange
        case .privateTrip: return .gray
        }
    }

    private func geocodeAddresses() async {
        focusedField = nil          // dismiss keyboard
        isGeocoding = true
        defer { isGeocoding = false }
        geocodeStatus = "Resolving…"
        let geocoder = CLGeocoder()
        var status: [String] = []

        if !homeInput.isEmpty {
            if let placemark = try? await geocoder.geocodeAddressString(homeInput).first,
               let coord = placemark.location?.coordinate {
                store.settings.homeAddress = homeInput
                store.settings.homeLat = coord.latitude
                store.settings.homeLng = coord.longitude
                status.append("Home ✓")
            } else {
                status.append("Home not found")
            }
        }

        if !workInput.isEmpty {
            if let placemark = try? await geocoder.geocodeAddressString(workInput).first,
               let coord = placemark.location?.coordinate {
                store.settings.workAddress = workInput
                store.settings.workLat = coord.latitude
                store.settings.workLng = coord.longitude
                status.append("Work ✓")
            } else {
                status.append("Work not found")
            }
        }

        store.save()
        geocodeStatus = status.joined(separator: " · ")
    }
}
