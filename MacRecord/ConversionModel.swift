import AVFoundation
import Observation
import os

/// Converts finished recordings to AAC (optional) and reports progress to the UI.
@MainActor @Observable
final class ConversionModel {
    var convertToAAC: Bool {
        didSet { UserDefaults.standard.set(convertToAAC, forKey: Self.key) }
    }

    private(set) var isRunning = false
    private(set) var fraction = 0.0
    private(set) var trackIndex = 0
    private(set) var trackCount = 0
    private(set) var currentName = ""
    private(set) var activeFolder: URL?
    private(set) var lastResult: String?
    private(set) var errors: [String] = []
    /// Bumped whenever a run ends, so lists can reload.
    private(set) var finishedRuns = 0

    private static let key = "convertToAAC"
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var task: Task<Void, Never>?

    init() { convertToAAC = UserDefaults.standard.bool(forKey: Self.key) }

    private struct Outcome: Sendable {
        var renames: [String: String] = [:]     // old file name -> new file name
        var savedBytes: Int64 = 0
        var errors: [String] = []
    }

    func clearResult() {
        lastResult = nil
        errors = []
    }

    func cancel() { cancelFlag.withLock { $0 = true } }

    /// Converts each file to .m4a; a CAF is deleted only after its conversion succeeded and was verified.
    func start(folder: URL, files: [URL]) {
        guard !isRunning else { return }
        let files = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        clearResult()
        isRunning = true
        fraction = 0
        trackIndex = 0
        trackCount = files.count
        currentName = ""
        activeFolder = folder
        cancelFlag.withLock { $0 = false }
        let flag = cancelFlag

        task = Task {
            let outcome = await Task.detached(priority: .utility) {
                Self.run(files: files, flag: flag) { fraction, index, name in
                    Task { @MainActor in
                        self.fraction = fraction
                        self.trackIndex = index
                        self.currentName = name
                    }
                }
            }.value

            Self.updateSession(in: folder, renames: outcome.renames)
            errors = outcome.errors
            if !outcome.renames.isEmpty {
                let saved = ByteCountFormatter.string(fromByteCount: outcome.savedBytes, countStyle: .file)
                lastResult = "Converted \(outcome.renames.count) of \(files.count) track\(files.count == 1 ? "" : "s") to AAC, saved \(saved)"
            }
            isRunning = false
            activeFolder = nil
            finishedRuns += 1
        }
    }

    // MARK: Worker (background thread)

    private nonisolated static func run(
        files: [URL], flag: OSAllocatedUnfairLock<Bool>,
        report: @escaping @Sendable (Double, Int, String) -> Void
    ) -> Outcome {
        var outcome = Outcome()
        let frames = files.map { (try? AVAudioFile(forReading: $0).length) ?? 0 }
        let totalFrames = Double(max(frames.reduce(0, +), 1))
        var done: Int64 = 0
        var lastReported = -1.0

        for (index, file) in files.enumerated() {
            if flag.withLock({ $0 }) { break }
            let name = file.lastPathComponent
            report(Double(done) / totalFrames, index + 1, name)
            let before = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                let converted = try AudioConverter.convertToAAC(
                    source: file,
                    progress: { local in
                        let overall = (Double(done) + local * Double(frames[index])) / totalFrames
                        if overall - lastReported >= 0.005 {
                            lastReported = overall
                            report(overall, index + 1, name)
                        }
                    },
                    isCancelled: { flag.withLock { $0 } })
                let after = (try? converted.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try FileManager.default.removeItem(at: file)           // only reached after a verified conversion
                outcome.renames[name] = converted.lastPathComponent
                outcome.savedBytes += Int64(before - after)
            } catch is AudioConverter.Cancelled {
                break
            } catch {
                outcome.errors.append("Kept \(name): \(error.localizedDescription)")
            }
            done += frames[index]
        }
        return outcome
    }

    /// Points session.json at the new file names so transcription still finds the audio.
    private static func updateSession(in folder: URL, renames: [String: String]) {
        guard !renames.isEmpty else { return }
        let url = folder.appendingPathComponent("session.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), var session = try? decoder.decode(SessionInfo.self, from: data) else { return }
        for index in session.tracks.indices {
            if let new = renames[session.tracks[index].file] { session.tracks[index].file = new }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(session).write(to: url, options: .atomic)
    }
}
