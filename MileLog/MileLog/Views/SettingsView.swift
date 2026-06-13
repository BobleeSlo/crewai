import SwiftUI
import CoreLocation

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var supabase: SupabaseService
    @State private var exportURL: URL?

    @State private var homeInput = ""
    @State private var workInput = ""
    @State private var geocodeStatus: String?

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
                    Text(store.settings.autoDetectEnabled
                         ? "The detector will be enabled when Phase 3b ships. Pair your cars under Vehicles to make the most of it."
                         : "When enabled, the app starts trips automatically when you start driving and ends them when you stop.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Stepper(value: $store.settings.stationaryTimeoutMinutes, in: 2...20) {
                        Text("End trip after \(store.settings.stationaryTimeoutMinutes) min stationary")
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

                Section("Export") {
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
            .onChange(of: store.settings.autoDetectEnabled) { _ in store.save() }
            .onChange(of: store.settings.stationaryTimeoutMinutes) { _ in store.save() }
        }
    }

    private func refreshExport() {
        exportURL = store.trips.isEmpty ? nil : store.exportCSV()
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
