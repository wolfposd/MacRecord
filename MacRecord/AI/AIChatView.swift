import SwiftUI

struct AIChatView: View {
    @Environment(AIConfigStore.self) private var ai
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(AIChatModel.self) private var chat
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear(perform: refreshContext)
        .onChange(of: transcription.folder) { refreshContext() }
    }

    private func refreshContext() {
        chat.setContext(transcript: transcription.transcriptText, folder: transcription.folder)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
            if let model = ai.selected {
                Text(model.name).font(.headline)
                if !model.modelName.isEmpty { Text(model.modelName).foregroundStyle(.secondary) }
            } else {
                Text("No AI model selected").font(.headline)
            }
            Spacer()
            Button("Reload transcript") { refreshContext() }
                .help("Send the current transcript (with renamed speakers) as context for the next message")
            Button("Clear") { chat.clear() }.disabled(chat.messages.isEmpty)
        }
        .padding(12)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if chat.messages.isEmpty {
                    ContentUnavailableView(
                        ai.selected == nil ? "No AI model selected" : "Ask about this transcript",
                        systemImage: "sparkles",
                        description: Text(ai.selected == nil
                            ? "Add a model in Settings › AI and click it to select it."
                            : "For example: “Summarize this recording” or “List the action items”."))
                        .padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message, streaming: chat.isStreaming && message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                        if let error = chat.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
            }
            .onChange(of: chat.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.error) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit(send)             // Return sends; Shift+Return inserts a newline
                .disabled(ai.selected == nil)
            if chat.isStreaming {
                Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button(action: send) { Label("Send", systemImage: "paperplane.fill") }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.selected == nil)
            }
        }
        .padding(12)
        .onAppear { inputFocused = true }
    }

    private func send() {
        guard let model = ai.selected else { return }
        let text = input
        input = ""
        chat.send(text, model: model, apiKey: ai.apiKey(for: model))
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let streaming: Bool

    var body: some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 60) }
            Group {
                if message.text.isEmpty && streaming {
                    ProgressView().controlSize(.small)
                } else {
                    Text(message.text).textSelection(.enabled)
                }
            }
            .padding(10)
            .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 60) }
        }
    }
}
