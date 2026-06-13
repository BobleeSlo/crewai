import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var supabase: SupabaseService
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
