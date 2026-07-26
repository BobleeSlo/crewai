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
    @State private var generationFailed = false
    /// `PDFReporter`'s generators are fully synchronous, main-thread Core
    /// Graphics work — tapping Generate previously gave zero loading
    /// feedback (no spinner, no button-state change), so a heavier
    /// logbook could visibly stall the UI with nothing reassuring the
    /// user anything was happening (round-3 UX review finding). A
    /// `Task.yield()` before the blocking call lets this state actually
    /// render first; true background generation isn't attempted here
    /// since `generate`'s closures can call back into main-actor-isolated
    /// Store lookups.
    @State private var isGenerating = false

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
            } else if generationFailed {
                // PDFReporter now returns nil on a write failure instead of
                // a "successful" Result pointing at a missing/corrupt file
                // — but tapping Generate and having nothing happen, with
                // no explanation, is its own confusing dead end for what's
                // often the actual tax deliverable the user needs (round-2
                // UX review finding).
                Section {
                    Text("Couldn't create the PDF — check available storage and try again.")
                        .foregroundColor(.red)
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
                Button {
                    Task {
                        isGenerating = true
                        await Task.yield()   // let the spinner actually render first
                        result = generate(selectedTrips)
                        generationFailed = (result == nil)
                        isGenerating = false
                    }
                } label: {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Text("Generate")
                    }
                }
                .disabled(selected.isEmpty || isGenerating)
            }
        }
    }

    private var quickFilterMenu: some View {
        Menu {
            Button("Select all") {
                selected = Set(candidateTrips.map(\.id))
                result = nil
                generationFailed = false
            }
            Button("Deselect all", role: .destructive) {
                selected.removeAll()
                result = nil
                generationFailed = false
            }
            Divider()
            Button("Business only") {
                selected = Set(candidateTrips.filter { $0.type == .business }.map(\.id))
                result = nil
                generationFailed = false
            }
            Button("Commute only") {
                selected = Set(candidateTrips.filter { $0.type == .commute }.map(\.id))
                result = nil
                generationFailed = false
            }
        } label: {
            Image(systemName: "checklist")
        }
        .accessibilityLabel("Selection filters")
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        result = nil   // invalidate the PDF — user must regenerate with new selection
        generationFailed = false
    }
}
