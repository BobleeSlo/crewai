import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reimbursement") {
                    HStack {
                        Text("Rate per km")
                        Spacer()
                        TextField("0.43", value: $store.reimbursementRate, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("€").foregroundColor(.secondary)
                    }
                }

                Section("Export") {
                    if let exportURL {
                        ShareLink("Export \(store.trips.count) trips as CSV", item: exportURL)
                    } else {
                        Text("No trips to export yet.")
                            .foregroundColor(.secondary)
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "MileLog")
                    LabeledContent("Mode", value: "Local (on this device)")
                }
            }
            .navigationTitle("Settings")
            .onAppear { refreshExport() }
            .onChange(of: store.trips.count) { _ in refreshExport() }
            .onChange(of: store.reimbursementRate) { _ in
                store.save()
                refreshExport()
            }
        }
    }

    private func refreshExport() {
        exportURL = store.trips.isEmpty ? nil : store.exportCSV()
    }
}
