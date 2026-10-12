import Foundation
import Observation

@MainActor @Observable
final class AIChatModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var error: String?
    /// Which transcript folder the conversation belongs to; the chat resets when it changes.
    private(set) var contextFolder: URL?
    private var system = ""
    private var task: Task<Void, Never>?

    static let instruction = """
        You are helping the user work with the transcript of an audio recording. The transcript follows. \
        Lines look like "[hh:mm:ss] Speaker: text". Answer based on it, in the user's language unless asked otherwise.
        """

    /// Captures the transcript as context. Clears the conversation if it is a different transcript.
    func setContext(transcript: String, folder: URL?) {
        if folder != contextFolder { clear() }
        contextFolder = folder
        system = Self.instruction + "\n\n--- TRANSCRIPT ---\n" + transcript
    }

    func send(_ text: String, model: AIModel, apiKey: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        error = nil
        messages.append(ChatMessage(role: .user, text: text))
        let history = messages
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isStreaming = true

        let system = system
        task = Task {
            defer { isStreaming = false }
            do {
                for try await chunk in AIChatClient.stream(model: model, apiKey: apiKey, system: system, messages: history) {
                    messages[index].text += chunk
                }
            } catch {
                self.error = error.localizedDescription
            }
            if messages[index].text.isEmpty && self.error != nil { messages.remove(at: index) }
        }
    }

    func stop() { task?.cancel() }

    func clear() {
        task?.cancel()
        messages = []
        error = nil
    }
}
