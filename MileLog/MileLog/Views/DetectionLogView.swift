import SwiftUI
import CoreLocation

struct DetectionLogView: View {
    @EnvironmentObject var detectionLog: DetectionLog
    @EnvironmentObject var detector: TripDetector

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    Text(detector.isEnabled ? "Monitoring" : "Off")
                        .foregroundColor(detector.isEnabled ? .green : .secondary)
                }
                LabeledContent("Permission", value: detector.permission.userText)
                LabeledContent("Active trip") {
                    if let trip = detector.activeTrip {
                        Text(String(format: "%.1f km", trip.distanceKm))
                            .foregroundColor(.blue)
                    } else {
                        Text("none").foregroundColor(.secondary)
                    }
                }
            }

            Section("Events") {
                if detectionLog.entries.isEmpty {
                    Text("No events yet.").foregroundColor(.secondary)
                } else {
                    ForEach(detectionLog.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message).font(.footnote)
                            Text(entry.timestamp, format: .dateTime.day().month().hour().minute().second())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .listRowBackground(background(for: entry.level))
                    }
                }
            }
        }
        .navigationTitle("Detection log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !detectionLog.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let url = detectionLog.exportAsFile() {
                            ShareLink(item: url) {
                                Label("Export & share log", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button(role: .destructive) {
                            detectionLog.clear()
                        } label: {
                            Label("Clear log", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func background(for level: DetectionLog.Level) -> Color {
        switch level {
        case .info:    return Color.clear
        case .warning: return Color.yellow.opacity(0.15)
        case .error:   return Color.red.opacity(0.15)
        }
    }
}

private extension CLAuthorizationStatus {
    var userText: String {
        switch self {
        case .notDetermined:        return "Not asked yet"
        case .restricted:           return "Restricted"
        case .denied:               return "Denied — fix in Settings"
        case .authorizedAlways:     return "Always ✓"
        case .authorizedWhenInUse:  return "While using — needs upgrade"
        @unknown default:           return "Unknown"
        }
    }
}
