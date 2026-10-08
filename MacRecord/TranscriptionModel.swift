import Foundation
import Observation
import SpeakerKit
import WhisperKit

struct TranscriptEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    private enum CodingKeys: String, CodingKey { case time, speakerKey, text }
    let time: Double            // seconds since the start of the session
    let speakerKey: String      // stable identity, see `TranscriptionModel.label(for:)`
    let text: String
}

/// Someone (or some source) heard in a track; the unit that can be renamed.
struct Speaker: Identifiable, Hashable, Codable {
    var id: String { key }
    let key: String             // "<track file>" for a single voice, "<track file>#<n>" for diarized speakers
    let defaultLabel: String    // e.g. "Microsoft Teams · Speaker 2"
    let trackSource: String     // owning track, for grouping in the UI
}

/// Saved next to Transcript.txt so a transcript can be reopened (with speakers and names) without re-running Whisper.
private struct StoredTranscript: Codable {
    struct Track: Codable { var file: String; var source: String; var language: String?; var speakers: Int? }
    var version = 1
    var model: String
    var entries: [TranscriptEntry]
    var speakers: [Speaker]
    var names: [String: String]
    var tracks: [Track]
}

private struct TrackResult {
    var entries: [TranscriptEntry]
    var speakers: [Speaker]
}

struct TrackProgress: Identifiable {
    enum State: Equatable { case waiting, running, done, failed(String) }
    let id: String              // file name
    let source: String
    var state: State = .waiting
    var language: String?
    var stage: String?
    var speakers: Int?
}

@MainActor @Observable
final class TranscriptionModel {
    enum Phase: Equatable { case idle, loadingModel, transcribing, finished, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var folder: URL?
    private(set) var modelTitle = ""
    private(set) var tracks: [TrackProgress] = []
    private(set) var entries: [TranscriptEntry] = []
    private(set) var outputFile: URL?
    private(set) var speakers: [Speaker] = []
    private(set) var names: [String: String] = [:]
    private(set) var saveError: String?
    private(set) var summary = ""

    private var task: Task<Void, Never>?

    private(set) var busyTrack: String?     // track being re-transcribed

    var isWorking: Bool { phase == .loadingModel || phase == .transcribing || busyTrack != nil }

    func start(folder: URL, modelID: String, store: WhisperModelStore) {
        guard !isWorking else { return }
        guard let model = WhisperModel.all.first(where: { $0.id == modelID }),
              let modelFolder = store.installedFolder(for: modelID) else {
            phase = .failed("The selected model is not installed. Download one in Settings.")
            return
        }
        self.folder = folder
        refreshSummary()
        modelTitle = model.title
        entries = []
        tracks = []
        speakers = []
        names = [:]
        saveError = nil
        outputFile = nil
        phase = .loadingModel
        let downloadBase = store.downloadBase
        let diarize = store.speakerIdentificationActive
        let languages = store.languages
        task = Task { await run(folder: folder, model: model, modelFolder: modelFolder, downloadBase: downloadBase, languages: languages, diarize: diarize) }
    }

    func cancel() { task?.cancel() }

    // MARK: Pipeline

    private struct Input {
        let url: URL
        let source: String
        let offset: Double
    }

    private func run(folder: URL, model: WhisperModel, modelFolder: URL, downloadBase: URL, languages: [String], diarize: Bool) async {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let inputs: [Input]
        do { inputs = try Self.loadInputs(in: folder) } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard !inputs.isEmpty else {
            phase = .failed("No .caf recordings found in this folder.")
            return
        }
        tracks = inputs.map { TrackProgress(id: $0.url.lastPathComponent, source: $0.source) }

        let pipe: WhisperKit
        do {
            pipe = try await Self.loadPipe(modelFolder: modelFolder, downloadBase: downloadBase)
        } catch {
            phase = .failed("Could not load the model: \(error.localizedDescription)")
            return
        }

        // Optional: tells speakers apart inside each track. If it can't load we just transcribe without it.
        var speakerKit: SpeakerKit?
        if diarize {
            speakerKit = try? await SpeakerKit(PyannoteConfig(
                downloadBase: downloadBase.path, download: false, load: true, verbose: false, logLevel: .none))
        }
        defer { if let speakerKit { Task { await speakerKit.unloadModels() } } }

        phase = .transcribing

        for (index, input) in inputs.enumerated() {
            if Task.isCancelled { break }
            tracks[index].state = .running
            do {
                let result = try await transcribeTrack(
                    index: index, input: input, languages: languages, pipe: pipe, speakerKit: speakerKit)
                entries = (entries + result.entries).sorted { $0.time < $1.time }
                speakers += result.speakers
                tracks[index].state = .done
            } catch {
                tracks[index].state = .failed(error.localizedDescription)
            }
        }

        if Task.isCancelled {
            phase = .failed("Cancelled")
            return
        }
        do {
            outputFile = folder.appendingPathComponent(Self.textName)
            try writeTranscript()
            phase = .finished
        } catch {
            outputFile = nil
            phase = .failed("Could not write Transcript.txt: \(error.localizedDescription)")
        }
    }

    private static func loadPipe(modelFolder: URL, downloadBase: URL) async throws -> WhisperKit {
        // The tokenizer is fetched once from Hugging Face into `downloadBase`, then cached.
        try await WhisperKit(WhisperKitConfig(
            downloadBase: downloadBase, modelFolder: modelFolder.path,
            verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
    }

    /// Transcribes (and optionally diarizes) one track. `languages`: empty = auto, one = fixed, several = best of those.
    private func transcribeTrack(
        index: Int, input: Input, languages: [String], pipe: WhisperKit, speakerKit: SpeakerKit?
    ) async throws -> TrackResult {
        var language = languages.count == 1 ? languages[0] : nil
        if languages.count > 1 {
            // Whisper can't take a list of languages, so score the audio and pick the best allowed one.
            if let probs = try? await pipe.detectLanguage(audioPath: input.url.path).langProbs {
                language = languages.max { (probs[$0] ?? -.infinity) < (probs[$1] ?? -.infinity) }
            }
        }
        tracks[index].language = language
        let options = DecodingOptions(
            task: .transcribe, language: language, usePrefillPrompt: true, detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: speakerKit != nil)
        let results = try await pipe.transcribe(
            audioPath: input.url.path, decodeOptions: options,
            callback: { _ in !Task.isCancelled })
        // With auto-detection the language is only known from the result.
        tracks[index].language = language ?? results.first?.language

        var diarizedResult: TrackResult?
        if let speakerKit {
            tracks[index].stage = "identifying speakers"
            diarizedResult = await Self.diarized(results, audioPath: input.url.path, input: input, speakerKit: speakerKit)
            tracks[index].speakers = diarizedResult?.speakers.count
        }
        tracks[index].stage = nil
        return diarizedResult ?? Self.plain(results, input: input)
    }

    // MARK: Re-transcribing one track

    private nonisolated static func keys(ofTrack file: String) -> @Sendable (Speaker) -> Bool {
        { $0.key == file || $0.key.hasPrefix(file + "#") }
    }

    /// True if the user gave custom names to speakers of this track (they would be lost by re-transcribing it).
    func hasCustomNames(track file: String) -> Bool {
        speakers.contains { Self.keys(ofTrack: file)($0) && !(names[$0.key] ?? "").isEmpty }
    }

    /// Redoes a single track with another language (`nil` = auto-detect) and replaces its lines and speakers.
    func retranscribe(track file: String, language: String?, store: WhisperModelStore) {
        guard !isWorking, phase == .finished, let folder,
              let index = tracks.firstIndex(where: { $0.id == file }) else { return }
        guard let modelID = store.selectedModelID, let modelFolder = store.installedFolder(for: modelID) else {
            saveError = "Select an installed Whisper model in Settings first."
            return
        }
        let downloadBase = store.downloadBase
        let diarize = store.speakerIdentificationActive
        saveError = nil
        busyTrack = file
        tracks[index].state = .running
        let previousLanguage = tracks[index].language
        task = Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer {
                if scoped { folder.stopAccessingSecurityScopedResource() }
                busyTrack = nil
            }
            do {
                guard let input = try Self.loadInputs(in: folder).first(where: { $0.url.lastPathComponent == file }) else {
                    throw AudioError.message("The audio file \(file) is no longer in the folder.")
                }
                let pipe = try await Self.loadPipe(modelFolder: modelFolder, downloadBase: downloadBase)
                var speakerKit: SpeakerKit?
                if diarize {
                    speakerKit = try? await SpeakerKit(PyannoteConfig(
                        downloadBase: downloadBase.path, download: false, load: true, verbose: false, logLevel: .none))
                }
                defer { if let speakerKit { Task { await speakerKit.unloadModels() } } }

                let languages = language.map { [$0] } ?? []
                let result = try await transcribeTrack(
                    index: index, input: input, languages: languages, pipe: pipe, speakerKit: speakerKit)
                try Task.checkCancellation()

                let belongs = Self.keys(ofTrack: file)
                let order = tracks.map(\.id)
                let oldKeys = Set(speakers.filter(belongs).map(\.key))
                entries = (entries.filter { !oldKeys.contains($0.speakerKey) } + result.entries).sorted { $0.time < $1.time }
                for key in oldKeys { names[key] = nil }
                speakers = (speakers.filter { !belongs($0) } + result.speakers).sorted { lhs, rhs in
                    func rank(_ s: Speaker) -> Int { order.firstIndex { Self.keys(ofTrack: $0)(s) } ?? .max }
                    return (rank(lhs), lhs.key) < (rank(rhs), rhs.key)
                }
                tracks[index].state = .done
                try writeTranscript()
            } catch {
                tracks[index].language = previousLanguage
                tracks[index].stage = nil
                tracks[index].state = error is CancellationError ? .done : .failed(error.localizedDescription)
            }
        }
    }

    private static func plain(_ results: [TranscriptionResult], input: Input) -> TrackResult {
        let key = input.url.lastPathComponent
        let entries = results.flatMap(\.segments).compactMap { segment -> TranscriptEntry? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptEntry(time: input.offset + Double(segment.start), speakerKey: key, text: text)
        }
        return TrackResult(
            entries: entries,
            speakers: entries.isEmpty ? [] : [Speaker(key: key, defaultLabel: input.source, trackSource: input.source)])
    }

    /// Splits the track's transcript by speaker. Returns nil if diarization isn't possible (caller falls back to plain).
    /// A track with one voice keeps its plain source name; otherwise "<Source> · Speaker N" (numbered by first appearance).
    private static func diarized(
        _ results: [TranscriptionResult], audioPath: String, input: Input, speakerKit: SpeakerKit
    ) async -> TrackResult? {
        guard let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath),
              let diarization = try? await speakerKit.diarize(audioArray: audio) else { return nil }

        let segments = diarization.addSpeakerInfo(to: results, strategy: .subsegment).flatMap { $0 }
        guard !segments.isEmpty else { return nil }

        var order: [Int] = []
        for segment in segments {
            if let id = segment.speaker.speakerId, !order.contains(id) { order.append(id) }
        }
        let file = input.url.lastPathComponent
        var speakers: [Speaker] = []
        func register(_ speaker: Speaker) {
            if !speakers.contains(where: { $0.key == speaker.key }) { speakers.append(speaker) }
        }

        let entries = segments.compactMap { segment -> TranscriptEntry? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var speaker = Speaker(key: file, defaultLabel: input.source, trackSource: input.source)
            if order.count > 1, let id = segment.speaker.speakerId, let n = order.firstIndex(of: id) {
                speaker = Speaker(key: "\(file)#\(n + 1)", defaultLabel: "\(input.source) · Speaker \(n + 1)",
                                  trackSource: input.source)
            }
            register(speaker)
            let start = segment.speakerWords.first?.wordTiming.start ?? segment.startTime
            return TranscriptEntry(time: input.offset + Double(start), speakerKey: speaker.key, text: text)
        }
        return TrackResult(entries: entries, speakers: speakers)
    }

    private static func loadInputs(in folder: URL) throws -> [Input] {
        let fm = FileManager.default
        let sessionURL = folder.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: sessionURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let session = try? decoder.decode(SessionInfo.self, from: data) {
                let found = session.tracks.compactMap { track -> Input? in
                    let url = folder.appendingPathComponent(track.file)
                    guard fm.fileExists(atPath: url.path), (track.frames ?? 1) > 0 else { return nil }
                    return Input(url: url, source: track.source, offset: track.startOffsetSeconds ?? 0)
                }
                if !found.isEmpty { return found }
            }
        }
        // No (usable) session.json: transcribe every .caf, all starting at 0.
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "caf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.map { Input(url: $0, source: $0.deletingPathExtension().lastPathComponent, offset: 0) }
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    // MARK: Summary

    /// Re-reads Summary.txt (e.g. after it was edited from the recordings list).
    func refreshSummary() {
        summary = folder.map { RecordingSummary.read(in: $0) } ?? ""
    }

    func setSummary(_ text: String) {
        guard let folder else { return }
        let clean = RecordingSummary.clamp(text)
        guard clean != summary else { return }
        do {
            try RecordingSummary.write(clean, in: folder)
            summary = clean
            saveError = nil
        } catch {
            saveError = "Could not save the summary: \(error.localizedDescription)"
        }
    }

    // MARK: Speaker names

    /// Custom name if one was given, otherwise the generated label.
    func label(for key: String) -> String {
        if let name = names[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return speakers.first { $0.key == key }?.defaultLabel ?? key
    }

    func customName(for key: String) -> String { names[key] ?? "" }

    /// Renames a speaker everywhere and rewrites Transcript.txt. An empty name restores the default label.
    func rename(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (names[key] ?? "") != trimmed else { return }
        names[key] = trimmed.isEmpty ? nil : trimmed
        guard phase == .finished else { return }
        do {
            try writeTranscript()
            saveError = nil
        } catch {
            saveError = "Could not update Transcript.txt: \(error.localizedDescription)"
        }
    }

    var transcriptText: String {
        let header = ["Transcript of \(folder?.lastPathComponent ?? "recording")", "Model: Whisper \(modelTitle)", ""]
        let lines = entries.map { "[\(Self.timestamp($0.time))] \(label(for: $0.speakerKey)): \($0.text)" }
        return (header + lines).joined(separator: "\n") + "\n"
    }

    private func writeTranscript() throws {
        guard let folder, let outputFile else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try transcriptText.write(to: outputFile, atomically: true, encoding: .utf8)
        let stored = StoredTranscript(
            model: modelTitle, entries: entries, speakers: speakers, names: names,
            tracks: tracks.map { .init(file: $0.id, source: $0.source, language: $0.language, speakers: $0.speakers) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: folder.appendingPathComponent(Self.jsonName), options: .atomic)
    }

    // MARK: Existing transcripts

    private static let textName = "Transcript.txt"
    private static let jsonName = "Transcript.json"

    static func hasTranscript(in folder: URL) -> Bool {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        return [jsonName, textName].contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Shows a transcript that was written earlier instead of transcribing again.
    func load(folder: URL) {
        guard !isWorking else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        self.folder = folder
        refreshSummary()
        entries = []; tracks = []; speakers = []; names = [:]; saveError = nil
        outputFile = folder.appendingPathComponent(Self.textName)

        if let data = try? Data(contentsOf: folder.appendingPathComponent(Self.jsonName)),
           let stored = try? JSONDecoder().decode(StoredTranscript.self, from: data) {
            modelTitle = stored.model
            entries = stored.entries
            speakers = stored.speakers
            names = stored.names
            tracks = stored.tracks.map {
                var track = TrackProgress(id: $0.file, source: $0.source, state: .done)
                track.language = $0.language
                track.speakers = $0.speakers
                return track
            }
            phase = .finished
        } else if let text = try? String(contentsOf: outputFile!, encoding: .utf8) {
            parsePlainText(text)       // older run that only produced Transcript.txt
            phase = .finished
        } else {
            outputFile = nil
            phase = .failed("No transcript found in this folder.")
        }
    }

    /// Fallback for Transcript.txt files without a JSON sidecar: lines look like `[hh:mm:ss] Label: text`.
    private func parsePlainText(_ text: String) {
        let pattern = /^\[(\d+):(\d\d):(\d\d)\] (.+?): (.*)$/
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Model: Whisper ") { modelTitle = String(line.dropFirst("Model: Whisper ".count)) }
            guard let match = line.wholeMatch(of: pattern) else { continue }
            let time = Double(Int(match.1)! * 3600 + Int(match.2)! * 60 + Int(match.3)!)
            let label = String(match.4)
            if !speakers.contains(where: { $0.key == label }) {
                speakers.append(Speaker(key: label, defaultLabel: label, trackSource: label))
            }
            entries.append(TranscriptEntry(time: time, speakerKey: label, text: String(match.5)))
        }
    }
}
