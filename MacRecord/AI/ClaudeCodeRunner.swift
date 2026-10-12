import Foundation

/// Runs the locally installed Claude Code CLI (`claude -p`) in the transcript folder and streams its answer.
/// Needs the App Sandbox to be off: the CLI has to be launched and must read ~/.claude and the folder itself.
enum ClaudeCodeRunner {
    /// The `claude` binary: the user's override if it exists, else the usual install locations, else a login shell lookup.
    static func locate(override: String = "") -> URL? {
        let fm = FileManager.default
        let custom = (override.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !custom.isEmpty { return fm.isExecutableFile(atPath: custom) ? URL(fileURLWithPath: custom) : nil }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let path = candidates.first(where: fm.isExecutableFile(atPath:)) { return URL(fileURLWithPath: path) }

        // GUI apps don't inherit the shell's PATH (nvm, custom prefixes), so ask a login shell.
        guard let out = shell("command -v claude"), out.hasPrefix("/"), fm.isExecutableFile(atPath: out) else { return nil }
        return URL(fileURLWithPath: out)
    }

    private static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// PATH of a login shell, so the CLI finds `node` and friends.
    private static let loginPath: String? = shell("echo $PATH")

    static func stream(
        model: AIModel, system: String, messages: [ChatMessage], folder: URL?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = locate(override: model.baseURL) else {
                continuation.finish(throwing: AIChatError.api(
                    "Claude Code was not found. Install it or set its path in Settings › AI › Claude Code."))
                return
            }

            let process = Process()
            process.executableURL = binary
            var args = ["-p", prompt(from: messages),
                        "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        "--tools", "Read,Grep,Glob",            // read-only: it may look at the transcript, nothing else
                        "--no-session-persistence",
                        "--append-system-prompt", system]
            let alias = model.modelName.trimmingCharacters(in: .whitespaces)
            if !alias.isEmpty { args += ["--model", alias] }
            process.arguments = args
            process.currentDirectoryURL = folder ?? FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            if let loginPath { env["PATH"] = loginPath }
            process.environment = env

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice      // otherwise the CLI waits for stdin

            let task = Task.detached {
                do {
                    try process.run()
                    // Drain stderr concurrently so a full pipe can't stall the CLI.
                    let errorData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }

                    var failure: String?
                    var needsBreak = false          // a new text block after earlier text (e.g. after a tool call)
                    var emitted = false
                    for try await line in out.fileHandleForReading.bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        switch json["type"] as? String {
                        case "stream_event":
                            guard let event = json["event"] as? [String: Any] else { continue }
                            switch event["type"] as? String {
                            case "content_block_start":
                                if (event["content_block"] as? [String: Any])?["type"] as? String == "text", emitted {
                                    needsBreak = true
                                }
                            case "content_block_delta":
                                guard let delta = event["delta"] as? [String: Any],
                                      delta["type"] as? String == "text_delta",
                                      let text = delta["text"] as? String, !text.isEmpty else { continue }
                                continuation.yield((needsBreak ? "\n\n" : "") + text)
                                needsBreak = false
                                emitted = true
                            default: break
                            }
                        case "result":
                            if json["is_error"] as? Bool == true {
                                failure = json["result"] as? String ?? "Claude Code reported an error."
                            }
                        default: break
                        }
                    }
                    process.waitUntilExit()
                    let stderr = String(data: await errorData.value, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if Task.isCancelled {
                        continuation.finish()
                    } else if let failure {
                        continuation.finish(throwing: AIChatError.api(failure))
                    } else if process.terminationStatus != 0 {
                        continuation.finish(throwing: AIChatError.api(
                            stderr.isEmpty ? "claude exited with status \(process.terminationStatus)." : String(stderr.suffix(600))))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? nil : error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// `-p` is stateless here, so earlier turns are replayed in the prompt.
    private static func prompt(from messages: [ChatMessage]) -> String {
        let turns = messages.filter { !$0.text.isEmpty }
        guard turns.count > 1, let last = turns.last else { return turns.last?.text ?? "" }
        let history = turns.dropLast().map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }
        return "Conversation so far:\n\n" + history.joined(separator: "\n\n") + "\n\nNew message from the user:\n" + last.text
    }
}
