import SwiftUI

struct AIChatView: View {
    @Environment(AIConfigStore.self) private var ai
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(AIChatModel.self) private var chat
    @State private var input = ""

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
            if ai.models.isEmpty {
                Text("No AI model selected").font(.headline)
            } else {
                @Bindable var ai = ai
                Picker("Model", selection: $ai.selectedID) {
                    if ai.selected == nil { Text("Select a model").tag(UUID?.none) }
                    ForEach(ai.models) { model in
                        Text(model.modelName.isEmpty ? model.name : "\(model.name) · \(model.modelName)")
                            .tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(chat.isStreaming)
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
            ComposerTextView(text: $input, isEnabled: ai.selected != nil, onSubmit: send)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                .overlay(alignment: .leading) {
                    if input.isEmpty {
                        Text("Message").foregroundStyle(.tertiary).padding(.leading, 8).allowsHitTesting(false)
                    }
                }
            if chat.isStreaming {
                Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button(action: send) { Label("Send", systemImage: "paperplane.fill") }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.selected == nil)
            }
        }
        .padding(12)
    }

    private func send() {
        guard let model = ai.selected, !chat.isStreaming,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
                    if isUser {
                        PlainMessageView(text: message.text)
                    } else {
                        MarkdownView(text: message.text)
                    }
                }
            }
            .padding(10)
            .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 60) }
        }
    }
}
