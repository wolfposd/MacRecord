import SwiftUI

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case ai = "AI"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .transcript: "text.bubble"
            case .ai: "sparkles"
            }
        }
    }

    @State private var selection: Pane? = .transcript

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 200)
        } detail: {
            switch selection ?? .transcript {
            case .transcript: TranscriptSettingsView()
            case .ai: AISettingsView()
            }
        }
        .frame(width: 780, height: 620)
    }
}

private enum AIRoute: Hashable { case form(AIProvider, UUID?) }      // nil id = add a new model

private struct AISettingsView: View {
    @Environment(AIConfigStore.self) private var ai
    @State private var path: [AIRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    if ai.models.isEmpty {
                        Text("No models yet. Add one from Available models below.").foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 10) {
                            ForEach(ai.models) { model in
                                ProviderBadge(
                                    title: model.name,
                                    subtitle: model.modelName,
                                    isSelected: ai.selectedID == model.id
                                ) { ai.selectedID = model.id }
                                .contextMenu {
                                    Button("Edit…") { path.append(.form(model.provider, model.id)) }
                                    Button("Remove", role: .destructive) { ai.remove(model) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Your Models")
                } footer: {
                    Text("Click a model to use it for processing transcripts. Right-click to edit or remove it.")
                }

                Section {
                    HStack(spacing: 10) {
                        ForEach(AIProvider.allCases) { provider in
                            ProviderBadge(title: provider.title, subtitle: nil, isSelected: false) {
                                // Claude is a single entry: reopen it for editing if it already exists.
                                let existing = provider == .claude ? ai.models.first { $0.provider == .claude }?.id : nil
                                path.append(.form(provider, existing))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Available models")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("AI")
            .navigationDestination(for: AIRoute.self) { route in
                switch route {
                case .form(let provider, let id): ModelFormView(provider: provider, editing: id)
                }
            }
        }
    }
}

/// Lays children out left to right and wraps them onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

private struct ProviderBadge: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected { Image(systemName: "checkmark.circle.fill") }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).fontWeight(.medium)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct ModelFormView: View {
    @Environment(AIConfigStore.self) private var ai
    @Environment(\.dismiss) private var dismiss
    let provider: AIProvider
    let editing: UUID?
    @State private var config = CustomAIConfig()

    var body: some View {
        Form {
            Section {
                if provider == .custom {
                    TextField("Name", text: $config.name, prompt: Text("My LLM"))
                    TextField("Base URL", text: $config.baseURL, prompt: Text("https://api.example.com/v1"))
                        .autocorrectionDisabled()
                }
                SecureField("API key", text: $config.apiKey)
                TextField("Model name", text: $config.modelName, prompt: Text("model-id"))
                    .autocorrectionDisabled()
            } footer: {
                Text(provider == .claude
                     ? "Uses the Anthropic API. The API key is stored in your Keychain."
                     : "Must be an OpenAI-compatible endpoint (…/chat/completions). The API key is stored in your Keychain and may be left empty for local servers.")
            }

            Section {
                HStack {
                    if let model = ai.models.first(where: { $0.id == editing }) {
                        Button("Remove", role: .destructive) {
                            ai.remove(model)
                            dismiss()
                        }
                    }
                    Spacer()
                    Button("Save") {
                        ai.save(config, provider: provider, id: editing)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!config.isValid(for: provider))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .onAppear {
            if let model = ai.models.first(where: { $0.id == editing }) {
                config = CustomAIConfig(
                    name: model.name, baseURL: model.baseURL, modelName: model.modelName, apiKey: ai.apiKey(for: model))
            } else if provider == .claude {
                config.modelName = AIConfigStore.defaultClaudeModel
            }
        }
    }

    private var title: String {
        switch (provider, editing) {
        case (.claude, _): "Anthropic Claude"
        case (.custom, nil): "Add custom model"
        case (.custom, _): "Edit model"
        }
    }
}

private struct TranscriptSettingsView: View {
    @Environment(WhisperModelStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach(WhisperModel.all) { model in
                    ModelRow(model: model)
                }
            } header: {
                Text("Transcription models")
            } footer: {
                Text("Models are downloaded from Hugging Face (argmaxinc/whisperkit-coreml) and run locally on this Mac.")
            }

            Section {
                ForEach(store.languages, id: \.self) { code in
                    HStack {
                        Text(WhisperModelStore.languageName(code))
                        Spacer()
                        Button { store.languages.removeAll { $0 == code } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless).help("Remove")
                    }
                }
                if store.languages.isEmpty {
                    Text("Auto-detect among all languages").foregroundStyle(.secondary)
                }
                Menu("Add language…") {
                    ForEach(WhisperModelStore.allLanguages.filter { !store.languages.contains($0.code) }, id: \.code) { language in
                        Button(language.name) { store.languages.append(language.code) }
                    }
                }
            } header: {
                Text("Transcription languages")
            } footer: {
                Text("Add one language to use it for everything. Add several (e.g. English and German) and each track is matched to the most likely one of them. Whisper uses one language per track, so speech that mixes languages within a track is not supported.")
            }

            Section {
                Toggle("Identify speakers", isOn: $store.identifySpeakers)
                    .disabled(store.speakerStatus != .installed)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speaker model  ").bold() + Text("≈ 33 MB").foregroundStyle(.secondary)
                        switch store.speakerStatus {
                        case .failed(let message):
                            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                        case .downloading:
                            ProgressView().controlSize(.small)
                        default:
                            Text("Pyannote diarization, runs locally").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    switch store.speakerStatus {
                    case .notInstalled, .failed:
                        Button("Download") { store.downloadSpeakerModel() }
                    case .downloading:
                        Button("Cancel", role: .cancel) { store.cancelSpeakerDownload() }
                    case .installed:
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button(role: .destructive) { store.deleteSpeakerModel() } label: { Image(systemName: "trash") }
                            .help("Delete model")
                    }
                }
            } header: {
                Text("Speaker identification")
            } footer: {
                Text("Tells the speakers apart within each recorded track (e.g. several people in a Teams call) and labels them Speaker 1, Speaker 2… A track with a single voice keeps its plain name. Transcription becomes somewhat slower.")
            }

            Section("Default model") {
                Picker("Use for transcription", selection: $store.selectedModelID) {
                    Text("None").tag(String?.none)
                    ForEach(WhisperModel.all.filter { store.status[$0.id] == .installed }) {
                        Text($0.title).tag(Optional($0.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcript")
    }
}

private struct ModelRow: View {
    @Environment(WhisperModelStore.self) private var store
    let model: WhisperModel

    var body: some View {
        let status = store.status[model.id] ?? .notInstalled
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.title)  ").bold() + Text(model.approxSize).foregroundStyle(.secondary)
                switch status {
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                    Text("Downloading… \(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                default:
                    Text(model.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch status {
            case .notInstalled, .failed:
                Button("Download") { store.download(model) }
            case .downloading:
                Button("Cancel", role: .cancel) { store.cancel(model) }
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button(role: .destructive) { store.delete(model) } label: { Image(systemName: "trash") }
                    .help("Delete model")
            }
        }
    }
}
