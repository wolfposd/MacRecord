import Foundation

/// A short free-text summary of a recording, stored as `Summary.txt` next to its audio and transcript.
/// A separate file keeps it cheap to list and lets it survive re-transcription.
enum RecordingSummary {
    static let maxLength = 200
    private static let fileName = "Summary.txt"

    /// Trims, turns line breaks into spaces and cuts to `maxLength` characters.
    static func clamp(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(maxLength))
    }

    static func read(in folder: URL) -> String {
        let text = try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8)
        return clamp(text ?? "")
    }

    /// Writes the summary; an empty one removes the file.
    static func write(_ text: String, in folder: URL) throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(fileName)
        let clean = clamp(text)
        if clean.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try clean.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
