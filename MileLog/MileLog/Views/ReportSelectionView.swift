import SwiftUI

/// Pre-PDF review screen: shows every trip eligible for a report, lets the
/// user check / uncheck individual rows (or use quick filters), and then
/// generates the PDF with only the selected subset.
///
/// Reused by both reports — the caller passes:
///   • `candidateTrips`: trips already filtered to the period.
///   • `formatRow`: how to render each row's middle content.
///   • `generate`: closure that produces the PDF from a chosen sub-array.
struct ReportSelectionView: View {
    let title: String
    let candidateTrips: [Trip]
    let formatRow: (Trip) -> AnyView
    let generate: ([Trip]) -> PDFReporter.Result?

    @State private var selected: Set<UUID>
    @State private var result: PDFReporter.Result?

    init(
        title: String,
        candidateTrips: [Trip],
        defaultSelected: [Trip]? = nil,
        formatRow: @escaping (Trip) -> AnyView,
        generate: @escaping ([Trip]) -> PDFReporter.Result?
    ) {
        self.title = title
        self.candidateTrips = candidateTrips
        self.formatRow = formatRow
        self.generate = generate
        _selected = State(initialValue: Set((defaultSelected ?? candidateTrips).map(\.id)))
    }

    private var selectedTrips: [Trip] {
        candidateTrips.filter { selected.contains($0.id) }
    }

    private var totalKm: Double {
        selectedTrips.reduce(0) { $0 + $1.distanceKm }
    }

    var body: some View {
        List {
            if candidateTrips.isEmpty {
                Section {
                    Text("No trips for this period.")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(candidateTrips) { trip in
                        Button {
                            toggle(trip.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(trip.id)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundColor(selected.contains(trip.id) ? .accentColor : .secondary)
                                    .font(.title3)
                                formatRow(trip)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("\(selected.count) of \(candidateTrips.count) selected")
                        Spacer()
                        Text(String(format: "%.1f km", totalKm))
                            .font(.caption.monospacedDigit())
                    }
                }
            }

            if let result {
                Section {
                    ShareLink(item: result.url) {
                        Label(
                            "Share PDF · \(result.tripCount) trips · \(String(format: "%.0f", result.headlineKm)) km",
                            systemImage: "square.and.arrow.up"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !candidateTrips.isEmpty { quickFilterMenu }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Generate") {
                    result = generate(selectedTrips)
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private var quickFilterMenu: some View {
        Menu {
            Button("Select all") {
                selected = Set(candidateTrips.map(\.id))
                result = nil
            }
            Button("Deselect all", role: .destructive) {
                selected.removeAll()
                result = nil
            }
            Divider()
            Button("Business only") {
                selected = Set(candidateTrips.filter { $0.type == .business }.map(\.id))
                result = nil
            }
            Button("Commute only") {
                selected = Set(candidateTrips.filter { $0.type == .commute }.map(\.id))
                result = nil
            }
        } label: {
            Image(systemName: "checklist")
        }
        .accessibilityLabel("Selection filters")
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        result = nil   // invalidate the PDF — user must regenerate with new selection
    }
}
