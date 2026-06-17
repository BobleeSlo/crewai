import SwiftUI
import CoreLocation

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var detector: TripDetector
    @EnvironmentObject var notifications: NotificationManager
    @State private var exportURL: URL?

    @State private var homeInput = ""
    @State private var workInput = ""
    @State private var geocodeStatus: String?
    @State private var isGeocoding = false

    // Monthly own-car PDF export state
    @State private var pdfYear: Int = Calendar.current.component(.year, from: Date())
    @State private var pdfMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var pdfResult: PDFReporter.Result?

    // Company car logbook PDF state
    @State private var logbookVehicleID: UUID?
    @State private var logbookYear: Int = Calendar.current.component(.year, from: Date())
    @State private var logbookMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var logbookResult: PDFReporter.Result?

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
                    Toggle(isOn: $store.settings.autoDetectEnabled) {
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
                        Button {
                            Task { await detector.requestEnable() }
                        } label: {
                            Label("Grant location permission", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    NavigationLink {
                        DetectionLogView()
                    } label: {
                        Label("Detection log", systemImage: "list.bullet.rectangle.portrait")
                    }
                } header: {
                    SectionHeaderLabel(title: "Auto-detect trips", systemImage: "dot.radiowaves.left.and.right")
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
                        store.applyAutomaticLocks()
                    } label: {
                        Label("Apply locks now", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
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

                    Button {
                        pdfResult = PDFReporter.generateMonthlyOwnCar(
                            trips: store.trips,
                            vehicleLookup: { store.vehicle($0) },
                            businessRate: store.settings.reimbursementRate,
                            commuteRate: store.settings.commuteRate,
                            year: pdfYear, month: pdfMonth
                        )
                    } label: {
                        Label("Generate own-car report", systemImage: "doc.richtext")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let pdfResult {
                        ShareLink(item: pdfResult.url) {
                            Label(
                                "Share PDF · \(pdfResult.tripCount) trips · \(String(format: "%.0f", pdfResult.headlineKm)) km",
                                systemImage: "square.and.arrow.up"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Own-car business + commute trips only. Private trips and company-car trips are excluded — give this PDF to your accountant for monthly reimbursement claims.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    SectionHeaderLabel(title: "Own-car monthly report", systemImage: "doc.text")
                }

                // MARK: Company car logbook (potni nalog)
                if !companyVehicles.isEmpty {
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
                        Button {
                            guard let id = logbookVehicleID, let v = store.vehicle(id) else { return }
                            logbookResult = PDFReporter.generateCompanyCarLogbook(
                                trips: store.trips,
                                vehicle: v,
                                year: logbookYear, month: logbookMonth
                            )
                        } label: {
                            Label("Generate potni nalog", systemImage: "book")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(logbookVehicleID == nil)

                        if let r = logbookResult {
                            ShareLink(item: r.url) {
                                Label(
                                    "Share PDF · \(r.tripCount) trips · \(String(format: "%.0f", r.headlineKm)) km",
                                    systemImage: "square.and.arrow.up"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("Slovenian potni nalog layout: date / departure / arrival / from / to / purpose / km. Odometer-start, odometer-end and signature columns are left blank so you can fill them by hand from the paper logbook.")
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
                            Label("Export \(store.trips.count) trips as CSV",
                                  systemImage: "tablecells")
                        }
                    } else {
                        Text("No trips to export yet.")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    SectionHeaderLabel(title: "All trips (CSV)", systemImage: "tablecells")
                }

                // MARK: Account
                Section {
                    LabeledContent("Signed in as", value: supabase.userEmail ?? "—")
                    Button(role: .destructive) {
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
            .onChange(of: store.settings.autoDetectEnabled) { _, enabled in
                store.save()
                Task {
                    if enabled {
                        _ = await notifications.requestPermission()
                        await detector.requestEnable()
                    } else {
                        detector.disable()
                    }
                }
            }
            .onChange(of: store.settings.stationaryTimeoutMinutes) { store.save() }
            .onChange(of: store.settings.lockAfterDays) { store.save() }
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
    private var companyVehicles: [Vehicle] {
        store.vehicles.filter { $0.type == .company }
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
