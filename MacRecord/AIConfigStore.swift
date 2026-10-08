import Foundation
import Observation
import Security

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claude, custom
    var id: String { rawValue }
    var title: String { self == .claude ? "Anthropic Claude" : "Custom" }
}

/// One model the user added, shown as a badge under "Your Models".
struct AIModel: Identifiable, Codable, Hashable {
    var id = UUID()
    var provider: AIProvider
    var name: String            // badge title
    var baseURL = ""
    var modelName = ""
    // The API key is not stored here; see `AIConfigStore.apiKey(for:)`.
}

/// Editable form state for the custom-model page.
struct CustomAIConfig: Equatable {
    var name = ""
    var baseURL = ""
    var modelName = ""
    var apiKey = ""

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelName.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host != nil
    }
}

/// The user's AI models and which one is used for transcript processing.
/// API keys live in the Keychain; everything else in UserDefaults.
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

    func apiKey(for model: AIModel) -> String { Keychain.read(account(model.id)) ?? "" }

    /// Adds a new custom model (`id == nil`) or updates an existing one, and selects it.
    func saveCustom(_ config: CustomAIConfig, id: UUID? = nil) {
        let name = config.name.trimmingCharacters(in: .whitespaces)
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespaces)
        let modelName = config.modelName.trimmingCharacters(in: .whitespaces)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var model = AIModel(provider: .custom, name: name, baseURL: baseURL, modelName: modelName)
        if let id, let index = models.firstIndex(where: { $0.id == id }) {
            model.id = id
            models[index] = model
        } else {
            models.append(model)
        }
        Keychain.write(key, account: account(model.id))
        selectedID = model.id
        persist()
    }

    /// Adds the built-in Anthropic Claude entry once.
    func addClaude() {
        if let existing = models.first(where: { $0.provider == .claude }) {
            selectedID = existing.id
            return
        }
        let model = AIModel(provider: .claude, name: AIProvider.claude.title)
        models.append(model)
        selectedID = model.id
        persist()
    }

    func remove(_ model: AIModel) {
        Keychain.delete(account(model.id))
        models.removeAll { $0.id == model.id }
        if selectedID == model.id { selectedID = nil }
        persist()
    }

    private func account(_ id: UUID) -> String { "aiKey-\(id.uuidString)" }
}

private enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "MacRecord"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account)
        guard !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
