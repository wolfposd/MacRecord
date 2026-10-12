import Foundation
import Observation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claude, claudeCode, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Anthropic Claude"
        case .claudeCode: "Claude Code"
        case .custom: "Custom"
        }
    }
    /// Singletons are a single entry with a fixed name; adding one again reopens the existing entry.
    var isSingleton: Bool { self != .custom }
}

/// One model the user added, shown as a badge under "Your Models".
struct AIModel: Identifiable, Codable, Hashable {
    var id = UUID()
    var provider: AIProvider
    var name: String            // badge title
    var baseURL = ""            // Claude Code: optional path of the `claude` binary
    var modelName = ""          // Claude Code: optional alias such as "sonnet"; empty = CLI default
    // The API key is not stored here; see `AIConfigStore.apiKey(for:)`.
}

/// Editable form state for the custom-model page.
struct CustomAIConfig: Equatable {
    var name = ""
    var baseURL = ""
    var modelName = ""
    var apiKey = ""

    func isValid(for provider: AIProvider) -> Bool {
        if provider == .claudeCode { return true }
        guard !modelName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch provider {
        case .claudeCode:
            return true
        case .claude:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .custom:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                && URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host != nil
        }
    }
}

/// The user's AI models and which one is used for transcript processing.
/// API keys live in a local file (see `KeyFile`); everything else in UserDefaults.
@MainActor @Observable
final class AIConfigStore {
    private(set) var models: [AIModel] = []
    var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: Keys.selected) }
    }

    var selected: AIModel? { models.first { $0.id == selectedID } }

    private enum Keys {
        static let models = "aiModels"
        static let selected = "aiSelectedModel"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.models),
           let stored = try? JSONDecoder().decode([AIModel].self, from: data) {
            models = stored
        }
        selectedID = defaults.string(forKey: Keys.selected).flatMap(UUID.init(uuidString:))
        if selected == nil { selectedID = nil }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(models) { UserDefaults.standard.set(data, forKey: Keys.models) }
    }

    // MARK: Models

    func apiKey(for model: AIModel) -> String { KeyFile.read(account(model.id)) ?? "" }

    nonisolated static let anthropicURL = "https://api.anthropic.com"
    nonisolated static let defaultClaudeModel = "claude-sonnet-5-5"

    /// Adds a new model (`id == nil`) or updates an existing one, and selects it.
    /// Claude is a single entry with a fixed name and endpoint; only key and model name are editable.
    func save(_ config: CustomAIConfig, provider: AIProvider, id: UUID? = nil) {
        var id = id
        if provider.isSingleton { id = id ?? models.first { $0.provider == provider }?.id }
        let name = provider.isSingleton ? provider.title : config.name.trimmingCharacters(in: .whitespaces)
        let baseURL = switch provider {
        case .claude: Self.anthropicURL
        case .claudeCode, .custom: config.baseURL.trimmingCharacters(in: .whitespaces)
        }
        let modelName = config.modelName.trimmingCharacters(in: .whitespaces)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var model = AIModel(provider: provider, name: name, baseURL: baseURL, modelName: modelName)
        if let id, let index = models.firstIndex(where: { $0.id == id }) {
            model.id = id
            models[index] = model
        } else {
            models.append(model)
        }
        if provider != .claudeCode { KeyFile.write(key, account: account(model.id)) }
        selectedID = model.id
        persist()
    }

    func remove(_ model: AIModel) {
        KeyFile.delete(account(model.id))
        models.removeAll { $0.id == model.id }
        if selectedID == model.id { selectedID = nil }
        persist()
    }

    private func account(_ id: UUID) -> String { "aiKey-\(id.uuidString)" }
}

/// API keys in a small JSON file inside the app's sandbox container (`Application Support/MacRecord/ai-keys.json`).
/// Deliberately not the Keychain: ad-hoc signed builds make macOS ask for permission after every rebuild.
/// The file is readable only by the current user and excluded from backups, but the keys are not encrypted.
private enum KeyFile {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRecord/ai-keys.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func store(_ keys: [String: String]) {
        let fm = FileManager.default
        var file = url
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(keys).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch {
            NSLog("MacRecord: could not save AI keys: \(error.localizedDescription)")   // never log the keys themselves
        }
    }

    static func read(_ account: String) -> String? { load()[account] }

    static func write(_ value: String, account: String) {
        var keys = load()
        if value.isEmpty { keys[account] = nil } else { keys[account] = value }
        store(keys)
    }

    static func delete(_ account: String) {
        var keys = load()
        guard keys.removeValue(forKey: account) != nil else { return }
        store(keys)
    }
}
