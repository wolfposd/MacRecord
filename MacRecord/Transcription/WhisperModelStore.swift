import Foundation
import Observation
import SpeakerKit
import WhisperKit

struct WhisperModel: Identifiable, Hashable {
    let id: String              // short key
    let title: String
    let variant: String         // folder name in argmaxinc/whisperkit-coreml
    let approxSize: String
    let note: String

    static let all: [WhisperModel] = [
        .init(id: "small", title: "Small", variant: "openai_whisper-small",
              approxSize: "≈ 490 MB", note: "Fastest, lowest accuracy"),
        .init(id: "large-v3-turbo", title: "Large v3 Turbo", variant: "openai_whisper-large-v3-v20240930_turbo",
              approxSize: "≈ 1.6 GB", note: "Near Large v3 accuracy, much faster"),
        .init(id: "large-v2", title: "Large v2", variant: "openai_whisper-large-v2",
              approxSize: "≈ 3.1 GB", note: "Most accurate, slowest"),
    ]
}

/// Downloads, tracks and deletes WhisperKit Core ML models stored in Application Support.
@MainActor @Observable
final class WhisperModelStore {
    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var status: [String: Status] = [:]
    var selectedModelID: String? {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Self.selectedKey) }
    }

    /// Whisper language codes (e.g. ["en", "de"]). Empty = auto-detect among all languages,
    /// one = use that language, several = detect per track, but only among these.
    var languages: [String] {
        didSet { UserDefaults.standard.set(languages, forKey: Self.languagesKey) }
    }

    /// (code, display name) for every language Whisper supports, sorted by name.
    static let allLanguages: [(code: String, name: String)] = {
        var best: [String: String] = [:]
        for (name, code) in Constants.languages where (best[code]?.count ?? .max) > name.count { best[code] = name }
        return best.map { ($0.key, $0.value.capitalized) }.sorted { $0.1 < $1.1 }
    }()

    // MARK: Speaker identification

    private(set) var speakerStatus: Status = .notInstalled
    var identifySpeakers: Bool {
        didSet { UserDefaults.standard.set(identifySpeakers, forKey: Self.identifyKey) }
    }
    /// True when speaker identification is switched on and its model is available.
    var speakerIdentificationActive: Bool { identifySpeakers && speakerStatus == .installed }
    private var speakerTask: Task<Void, Never>?
    private static let identifyKey = "identifySpeakers"

    var speakerFolder: URL {
        downloadBase.appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
    }

    func downloadSpeakerModel() {
        guard speakerTask == nil else { return }
        speakerStatus = .downloading(0)
        let base = downloadBase
        speakerTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                _ = try await SpeakerKit(PyannoteConfig(
                    downloadBase: base.path, download: true, load: false, verbose: false, logLevel: .none))
                try Task.checkCancellation()
                guard let self else { return }
                FileManager.default.createFile(
                    atPath: self.speakerFolder.appendingPathComponent(Self.marker).path, contents: Data())
                self.speakerStatus = .installed
                self.speakerTask = nil
            } catch is CancellationError {
                self?.speakerStatus = .notInstalled
                self?.speakerTask = nil
            } catch {
                self?.speakerStatus = .failed(error.localizedDescription)
                self?.speakerTask = nil
            }
        }
    }

    func cancelSpeakerDownload() { speakerTask?.cancel() }

    func deleteSpeakerModel() {
        try? FileManager.default.removeItem(at: speakerFolder)
        speakerStatus = .notInstalled
    }

    private var tasks: [String: Task<Void, Never>] = [:]
    private static let selectedKey = "selectedWhisperModel"
    private static let languagesKey = "whisperLanguages"
    private static let legacyLanguageKey = "whisperLanguage"
    private static let marker = ".macrecord-complete"

    /// Models live in `<Application Support>/MacRecord/Models/models/argmaxinc/whisperkit-coreml/<variant>`.
    let downloadBase: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MacRecord/Models", isDirectory: true)
    }()

    init() {
        selectedModelID = UserDefaults.standard.string(forKey: Self.selectedKey)
        let defaults = UserDefaults.standard
        identifySpeakers = defaults.bool(forKey: Self.identifyKey)
        languages = defaults.stringArray(forKey: Self.languagesKey)
            ?? defaults.string(forKey: Self.legacyLanguageKey).map { [$0] } ?? []
        for model in WhisperModel.all {
            status[model.id] = isInstalled(model) ? .installed : .notInstalled
        }
        if let id = selectedModelID, status[id] != .installed { selectedModelID = nil }
        if FileManager.default.fileExists(atPath: speakerFolder.appendingPathComponent(Self.marker).path) {
            speakerStatus = .installed
        }
    }

    func folder(for model: WhisperModel) -> URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.variant)", isDirectory: true)
    }

    /// Folder to hand to WhisperKit for transcription, if the model is installed.
    func installedFolder(for id: String) -> URL? {
        guard let model = WhisperModel.all.first(where: { $0.id == id }), isInstalled(model) else { return nil }
        return folder(for: model)
    }

    private func isInstalled(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: model).appendingPathComponent(Self.marker).path)
    }

    func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil else { return }
        status[model.id] = .downloading(0)
        let base = downloadBase
        tasks[model.id] = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let folder = try await WhisperKit.download(
                    variant: model.variant, downloadBase: base
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        guard let self, case .downloading = self.status[model.id] else { return }
                        self.status[model.id] = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                FileManager.default.createFile(
                    atPath: folder.appendingPathComponent(Self.marker).path, contents: Data())
                self?.finish(model, .installed)
                if self?.selectedModelID == nil { self?.selectedModelID = model.id }
            } catch is CancellationError {
                self?.finish(model, .notInstalled)
            } catch {
                self?.finish(model, .failed(error.localizedDescription))
            }
        }
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
    }

    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: folder(for: model))
        status[model.id] = .notInstalled
        if selectedModelID == model.id { selectedModelID = nil }
    }

    private func finish(_ model: WhisperModel, _ result: Status) {
        tasks[model.id] = nil
        status[model.id] = result
        if result == .notInstalled { try? FileManager.default.removeItem(at: folder(for: model)) }
    }
}

extension WhisperModelStore {
    static func languageName(_ code: String) -> String {
        allLanguages.first { $0.code == code }?.name ?? code
    }
}
