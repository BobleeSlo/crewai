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

    // Monthly PDF export state
    @State private var pdfYear: Int = Calendar.current.component(.year, from: Date())
    @State private var pdfMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var pdfResult: PDFReporter.Result?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reimbursement") {
                    HStack {
                        Text("Rate per km")
                        Spacer()
                        TextField("0.43", value: $store.settings.reimbursementRate, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€").foregroundColor(.secondary)
                    }
                }

                Section("Auto-detect trips") {
                    Toggle("Detect trips automatically", isOn: $store.settings.autoDetectEnabled)
                    Text(autoDetectHint)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Stepper(value: $store.settings.stationaryTimeoutMinutes, in: 2...20) {
                        Text("End trip after \(store.settings.stationaryTimeoutMinutes) min stationary")
                    }

                    if store.settings.autoDetectEnabled && detector.permission != .authorizedAlways {
                        Button("Grant location permission") {
                            Task { await detector.requestEnable() }
                        }
                    }

                    NavigationLink("Detection log") {
                        DetectionLogView()
                    }
                }

                Section("Home & Work") {
                    TextField("Home address", text: $homeInput)
                        .textInputAutocapitalization(.words)
                    if let lat = store.settings.homeLat, let lng = store.settings.homeLng {
                        LabeledContent("Home location") {
                            Text(String(format: "%.4f, %.4f", lat, lng))
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }

                    TextField("Work address", text: $workInput)
                        .textInputAutocapitalization(.words)
                    if let lat = store.settings.workLat, let lng = store.settings.workLng {
                        LabeledContent("Work location") {
                            Text(String(format: "%.4f, %.4f", lat, lng))
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }

                    Button("Resolve addresses") {
                        Task { await geocodeAddresses() }
                    }
                    .disabled(homeInput.isEmpty && workInput.isEmpty)

                    if let geocodeStatus {
                        Text(geocodeStatus).font(.footnote).foregroundColor(.secondary)
                    }

                    Text("Used to recognize commute trips (Home → Work mornings, Work → Home evenings).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Monthly PDF logbook") {
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

                    Button("Generate PDF") {
                        pdfResult = PDFReporter.generateMonthly(
                            trips: store.trips,
                            vehicleLookup: { store.vehicle($0) },
                            rate: store.settings.reimbursementRate,
                            year: pdfYear,
                            month: pdfMonth
                        )
                    }

                    if let pdfResult {
                        ShareLink(
                            "Share PDF (\(pdfResult.tripCount) trips · \(String(format: "%.0f", pdfResult.businessKm)) km business)",
                            item: pdfResult.url
                        )
                    }
                }

                Section("All trips (CSV)") {
                    if let exportURL {
                        ShareLink("Export \(store.trips.count) trips as CSV", item: exportURL)
                    } else {
                        Text("No trips to export yet.")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Account") {
                    LabeledContent("Signed in as", value: supabase.userEmail ?? "—")
                    Button("Sign out", role: .destructive) {
                        Task { await supabase.signOut() }
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "MileLog")
                    LabeledContent("Sync", value: "Supabase cloud")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                refreshExport()
                homeInput = store.settings.homeAddress
                workInput = store.settings.workAddress
            }
            .onChange(of: store.trips.count) { _ in refreshExport() }
            .onChange(of: store.settings.reimbursementRate) { _ in
                store.save()
                refreshExport()
            }
            .onChange(of: store.settings.autoDetectEnabled) { enabled in
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
            .onChange(of: store.settings.stationaryTimeoutMinutes) { _ in store.save() }
        }
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

    private func geocodeAddresses() async {
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
