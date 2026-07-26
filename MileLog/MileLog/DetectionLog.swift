import Foundation
import Combine

/// In-memory + on-disk debug log of detection events.
/// Capped at 100 entries so it never grows unbounded.
@MainActor
final class DetectionLog: ObservableObject {

    enum Level: String, Codable {
        case info, warning, error
    }

    struct Entry: Identifiable, Codable, Hashable {
        let id: UUID
        let timestamp: Date
        let level: Level
        let message: String

        init(level: Level, message: String) {
            id = UUID()
            timestamp = Date()
            self.level = level
            self.message = message
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let url: URL
    private let limit = 100

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("detection-log.json")
        load()
    }

    func log(_ message: String, level: Level = .info) {
        let entry = Entry(level: level, message: message)
        entries.insert(entry, at: 0)
        if entries.count > limit { entries = Array(entries.prefix(limit)) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Export

    /// Plain-text dump of every entry, oldest first, with ISO timestamps —
    /// suitable for emailing back for diagnosis when something went wrong.
    func exportAsText() -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = """
        MileLog Detection Log
        Generated: \(df.string(from: Date()))
        Entries: \(entries.count)
        --------------------------------------------------------------------------------
        """
        let body = entries
            .reversed()                                          // oldest first
            .map { entry in
                "\(df.string(from: entry.timestamp))  [\(entry.level.rawValue.uppercased())]  \(entry.message)"
            }
            .joined(separator: "\n")
        return header + "\n" + body + "\n"
    }

    /// Writes the export to a temp file and returns the URL, ready for ShareLink.
    func exportAsFile() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "MileLog-DetectionLog-\(df.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try exportAsText().data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
