import Foundation
import Observation
import SpeakerKit
import WhisperKit

struct TranscriptEntry: Identifiable, Hashable {
    let id = UUID()
    let time: Double            // seconds since the start of the session
    let source: String
    let text: String
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

    private var task: Task<Void, Never>?

    var isWorking: Bool { phase == .loadingModel || phase == .transcribing }

    func start(folder: URL, modelID: String, store: WhisperModelStore) {
        guard !isWorking else { return }
        guard let model = WhisperModel.all.first(where: { $0.id == modelID }),
              let modelFolder = store.installedFolder(for: modelID) else {
            phase = .failed("The selected model is not installed. Download one in Settings.")
            return
        }
        self.folder = folder
        modelTitle = model.title
        entries = []
        tracks = []
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
            // The tokenizer is fetched once from Hugging Face into `downloadBase`, then cached.
            pipe = try await WhisperKit(WhisperKitConfig(
                downloadBase: downloadBase, modelFolder: modelFolder.path,
                verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
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
                var new: [TranscriptEntry]?
                if let speakerKit {
                    tracks[index].stage = "identifying speakers"
                    new = await Self.diarized(results, audioPath: input.url.path, input: input, speakerKit: speakerKit)
                    tracks[index].speakers = new.map { Set($0.map(\.source)).count }
                }
                tracks[index].stage = nil
                let entriesForTrack = new ?? Self.plain(results, input: input)
                entries = (entries + entriesForTrack).sorted { $0.time < $1.time }
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
            let file = folder.appendingPathComponent("Transcript.txt")
            try Self.render(entries: entries, model: model.title, folder: folder)
                .write(to: file, atomically: true, encoding: .utf8)
            outputFile = file
            phase = .finished
        } catch {
            phase = .failed("Could not write Transcript.txt: \(error.localizedDescription)")
        }
    }

    private static func plain(_ results: [TranscriptionResult], input: Input) -> [TranscriptEntry] {
        results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptEntry(time: input.offset + Double(segment.start), source: input.source, text: text)
        }
    }

    /// Splits the track's transcript by speaker. Returns nil if diarization isn't possible (caller falls back to plain).
    /// A track with one voice keeps its plain source name; otherwise "<Source> · Speaker N" (numbered by first appearance).
    private static func diarized(
        _ results: [TranscriptionResult], audioPath: String, input: Input, speakerKit: SpeakerKit
    ) async -> [TranscriptEntry]? {
        guard let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath),
              let diarization = try? await speakerKit.diarize(audioArray: audio) else { return nil }

        let segments = diarization.addSpeakerInfo(to: results, strategy: .subsegment).flatMap { $0 }
        guard !segments.isEmpty else { return nil }

        var order: [Int] = []
        for segment in segments {
            if let id = segment.speaker.speakerId, !order.contains(id) { order.append(id) }
        }
        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var label = input.source
            if order.count > 1, let id = segment.speaker.speakerId, let n = order.firstIndex(of: id) {
                label = "\(input.source) · Speaker \(n + 1)"
            }
            let start = segment.speakerWords.first?.wordTiming.start ?? segment.startTime
            return TranscriptEntry(time: input.offset + Double(start), source: label, text: text)
        }
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

    private static func render(entries: [TranscriptEntry], model: String, folder: URL) -> String {
        var lines = ["Transcript of \(folder.lastPathComponent)", "Model: Whisper \(model)", ""]
        lines += entries.map { "[\(timestamp($0.time))] \($0.source): \($0.text)" }
        return lines.joined(separator: "\n") + "\n"
    }
}
