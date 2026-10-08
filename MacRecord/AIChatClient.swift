import Foundation

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

enum AIChatError: LocalizedError {
    case badURL
    case http(Int, String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "The base URL of this model is not valid."
        case .http(let code, let body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .api(let message): message
        }
    }
}

/// Streams a chat completion as text chunks. Anthropic models use the Messages API,
/// custom models the OpenAI-compatible `/chat/completions` API.
enum AIChatClient {
    static func stream(
        model: AIModel, apiKey: String, system: String, messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(model: model, apiKey: apiKey, system: system, messages: messages)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw AIChatError.http(http.statusCode, errorText(from: body))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let chunk = try text(from: json, provider: model.provider) { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeRequest(
        model: AIModel, apiKey: String, system: String, messages: [ChatMessage]
    ) throws -> URLRequest {
        let history = messages.filter { !$0.text.isEmpty }.map { ["role": $0.role.rawValue, "content": $0.text] }
        var request: URLRequest
        var body: [String: Any]

        switch model.provider {
        case .claude:
            request = URLRequest(url: URL(string: AIConfigStore.anthropicURL + "/v1/messages")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model.modelName, "max_tokens": 4096, "system": system, "messages": history, "stream": true]
        case .custom:
            var base = model.baseURL.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: base + "/chat/completions") else { throw AIChatError.badURL }
            request = URLRequest(url: url)
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            body = ["model": model.modelName, "messages": [["role": "system", "content": system]] + history, "stream": true]
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Extracts the text delta of one SSE event; throws for provider error events.
    private static func text(from json: [String: Any], provider: AIProvider) throws -> String? {
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIChatError.api(message)
        }
        switch provider {
        case .claude:
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any] else { return nil }
            return delta["text"] as? String
        case .custom:
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { return nil }
            return delta["content"] as? String
        }
    }

    /// Pulls `error.message` out of a JSON error body, falling back to the raw text.
    private static func errorText(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(body.prefix(300))
    }
}
