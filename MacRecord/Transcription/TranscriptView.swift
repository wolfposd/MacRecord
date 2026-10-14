import SwiftUI

struct TranscriptView: View {
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(WhisperModelStore.self) private var store
    @Environment(ConversionModel.self) private var conversion
    @Environment(\.openWindow) private var openWindow
    @State private var player = ClipPlayer()
    @State private var pending: PendingLanguage?
    @State private var confirmRestart = false
    @State private var noModelAlert = false
    @State private var confirmRemoveAudio = false

    private struct PendingLanguage: Identifiable {
        let track: String
        let language: String?
        var id: String { track }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if transcription.phase == .finished {
                SummaryField()
                Divider()
            }
            if transcription.phase == .finished, !transcription.speakers.isEmpty {
                SpeakersPanel()
                Divider()
            }
            if transcription.phase == .idle, transcription.folder != nil, transcription.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Not transcribed yet").font(.title3)
                    Button("Start transcription", action: startOver)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(transcription.audioFiles.isEmpty || convertingHere)
                    if transcription.audioFiles.isEmpty {
                        Text("This recording has no audio files.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if transcription.entries.isEmpty {
                ContentUnavailableView(
                    placeholderTitle, systemImage: "text.bubble",
                    description: Text(placeholderText))
                    .frame(maxHeight: .infinity)
            } else {
                transcript
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 720)
        .onAppear { transcription.refreshAudio() }
        .onChange(of: conversion.finishedRuns) { transcription.refreshAudio() }
        .onChange(of: transcription.phase) { transcription.refreshAudio() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: restart) { Label("Restart Transcription", systemImage: "arrow.clockwise") }
                    .help("Transcribe this recording again")
                    .disabled(transcription.folder == nil || transcription.isWorking || transcription.phase == .idle
                              || transcription.audioFiles.isEmpty || convertingHere)
            }
        }
        .confirmationDialog("Remove the audio files?", isPresented: $confirmRemoveAudio) {
            Button("Remove Audio Files", role: .destructive) { transcription.removeAudioFiles() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(transcription.audioFiles.count) audio file\(transcription.audioFiles.count == 1 ? "" : "s") of this recording. The transcript is kept, but the transcription can no longer be redone or its language changed.")
        }
        .confirmationDialog("Restart the transcription?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive, action: startOver)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current transcript and resets any speaker names you set.")
        }
        .alert("No transcription model", isPresented: $noModelAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Download a Whisper model in Settings (⌘,) first.")
        }
        .confirmationDialog(
            "Transcribe this track again?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { item in
            Button("Re-transcribe", role: .destructive) {
                transcription.retranscribe(track: item.track, language: item.language, store: store)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The speakers of this track are detected again, so the names you gave them will be reset.")
        }
    }

    private var placeholderTitle: String {
        switch transcription.phase {
        case .idle: "No transcript yet"
        case .loadingModel: "Loading model…"
        case .transcribing: "Transcribing…"
        case .finished: "No speech found"
        case .failed: "Transcription failed"
        }
    }

    private var placeholderText: String {
        switch transcription.phase {
        case .idle: "Press Transcribe in the main window and choose a recording folder."
        case .failed(let message): message
        default: ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(transcription.folder?.lastPathComponent ?? "Transcript").font(.headline)
                if !transcription.modelTitle.isEmpty {
                    Text("Whisper \(transcription.modelTitle)").foregroundStyle(.secondary)
                }
                Spacer()
                if transcription.isWorking { ProgressView().controlSize(.small) }
            }
            if !transcription.tracks.isEmpty {
                ForEach(transcription.tracks) { track in
                    HStack(spacing: 6) {
                        switch track.state {
                        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                        case .running: ProgressView().controlSize(.mini)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        Text(track.source).font(.callout)
                        languageControl(for: track)
                        if let stage = track.stage {
                            Text(stage).font(.caption).foregroundStyle(.secondary)
                        }
                        if let speakers = track.speakers {
                            Text(speakers == 1 ? "1 speaker" : "\(speakers) speakers")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if case .failed(let message) = track.state {
                            Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Detected/used language. After a finished run it is a menu that re-transcribes just this track.
    @ViewBuilder
    private func languageControl(for track: TrackProgress) -> some View {
        let name = track.language.map(WhisperModelStore.languageName)
        if transcription.phase == .finished, !transcription.isWorking, track.state != .running,
           !transcription.audioFiles.isEmpty, !convertingHere {
            Menu {
                if !store.languages.isEmpty {
                    ForEach(store.languages, id: \.self) { code in
                        Button(WhisperModelStore.languageName(code)) { choose(code, for: track) }
                    }
                    Divider()
                }
                Button("Auto-detect") { choose(nil, for: track) }
                Menu("All languages") {
                    ForEach(WhisperModelStore.allLanguages, id: \.code) { language in
                        Button(language.name) { choose(language.code, for: track) }
                    }
                }
            } label: {
                Text(name ?? "Language")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Wrong language? Pick another one to transcribe this track again")
        } else if let name {
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func restart() {
        guard store.selectedModelID != nil else { noModelAlert = true; return }
        confirmRestart = true
    }

    private func startOver() {
        guard let folder = transcription.folder else { return }
        guard let id = store.selectedModelID else { noModelAlert = true; return }
        transcription.start(folder: folder, modelID: id, store: store)
    }

    private func choose(_ code: String?, for track: TrackProgress) {
        guard code != track.language || code == nil else { return }
        if transcription.hasCustomNames(track: track.id) {
            pending = PendingLanguage(track: track.id, language: code)    // confirm: names would be lost
        } else {
            transcription.retranscribe(track: track.id, language: code, store: store)
        }
    }

    private var transcript: some View {
        let labels = Array(Set(transcription.entries.map { transcription.label(for: $0.speakerKey) })).sorted()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(transcription.entries) { entry in
                    let label = transcription.label(for: entry.speakerKey)
                    let clip = transcription.clip(for: entry)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button {
                            if let clip {
                                player.toggle(id: entry.id, url: clip.url, start: clip.start, end: clip.end,
                                              folder: transcription.folder)
                            }
                        } label: {
                            Image(systemName: player.playingID == entry.id ? "stop.circle.fill" : "play.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .opacity(clip == nil ? 0 : 1)
                        .disabled(clip == nil)
                        .help("Play this line")
                        Text(TranscriptionModel.timestamp(entry.time))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        SpeakerLabel(key: entry.speakerKey, label: label, color: color(for: label, in: labels))
                        EditableLine(text: entry.text) { transcription.setText(entry.id, to: $0) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for source: String, in sources: [String]) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
        return palette[(sources.firstIndex(of: source) ?? 0) % palette.count]
    }

    /// True while this recording's audio is being compressed.
    private var convertingHere: Bool {
        conversion.isRunning && conversion.activeFolder == transcription.folder
    }

    @ViewBuilder
    private var footer: some View {
        if convertingHere {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView(value: conversion.fraction)
                    Button("Cancel") { conversion.cancel() }
                }
                Text("Compressing to AAC… \(Int(conversion.fraction * 100)) % — track \(conversion.trackIndex) of \(conversion.trackCount)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 12)
        } else if conversion.lastFolder == transcription.folder,
                  conversion.lastResult != nil || !conversion.errors.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let result = conversion.lastResult {
                    Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                ForEach(conversion.errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        buttonBar
    }

    private var buttonBar: some View {
        HStack {
            switch transcription.phase {
            case .finished:
                Label("Saved Transcript.txt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case _ where transcription.saveError != nil:
                Label(transcription.saveError ?? "", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).lineLimit(1)
            case .failed(let message) where !transcription.entries.isEmpty:
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
            default:
                EmptyView()
            }
            Spacer()
            if transcription.isWorking {
                Button("Cancel") { transcription.cancel() }
            }
            Button {
                if let folder = transcription.folder { conversion.start(folder: folder, files: transcription.cafFiles) }
            } label: { Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left") }
                .disabled(transcription.cafFiles.isEmpty || transcription.isWorking || conversion.isRunning)
                .help(transcription.cafFiles.isEmpty
                      ? "No uncompressed (.caf) audio left to compress"
                      : "Convert the audio to AAC (about 30× smaller); the .caf files are deleted after a successful conversion")
            Button { confirmRemoveAudio = true } label: { Label("Remove Audio", systemImage: "trash") }
                .disabled(transcription.audioFiles.isEmpty || transcription.isWorking || conversion.isRunning)
                .help("Delete the audio files of this recording and keep only the transcript")
            Button { openWindow(id: "ai-chat") } label: { Label("AI", systemImage: "sparkles") }
                .disabled(transcription.phase != .finished)
                .help("Chat with your selected AI model about this transcript")
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcription.transcriptText, forType: .string)
            }.disabled(transcription.entries.isEmpty)
            Button("Show in Finder") {
                if let file = transcription.outputFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }.disabled(transcription.outputFile == nil)
        }
        .padding(12)
    }
}

/// Speaker name shown in front of each line; click to rename that speaker.
/// A transcript line that turns into a text field when clicked.
private struct EditableLine: View {
    let text: String
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(finish)
                .onChange(of: focused) { _, isFocused in if !isFocused { finish() } }
                .onExitCommand { editing = false }
        } else {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { draft = text; editing = true; focused = true }
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        onCommit(draft)
    }
}

private struct SpeakerLabel: View {
    @Environment(TranscriptionModel.self) private var transcription
    let key: String
    let label: String
    let color: Color
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Text(label).font(.caption.bold()).foregroundStyle(color)
                .frame(width: 160, alignment: .leading).lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Click to rename")
        .popover(isPresented: $editing) {
            RenameField(key: key).padding(12).frame(width: 240)
        }
    }
}

private struct RenameField: View {
    @Environment(TranscriptionModel.self) private var transcription
    let key: String
    @State private var text = ""

    var body: some View {
        TextField(transcription.label(for: key), text: $text)
            .onAppear { text = transcription.customName(for: key) }
            .onSubmit { transcription.rename(key, to: text) }
            .onDisappear { transcription.rename(key, to: text) }
    }
}

/// Lists everyone found in the recording, grouped by track, with a name field for each.
private struct SpeakersPanel: View {
    @Environment(TranscriptionModel.self) private var transcription

    var body: some View {
        let groups = Dictionary(grouping: transcription.speakers, by: \.trackSource)
        let order = transcription.speakers.map(\.trackSource).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Speakers — type a name to rename").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(order, id: \.self) { track in
                        ForEach(groups[track] ?? []) { speaker in
                            SpeakerNameRow(speaker: speaker)
                        }
                    }
                }
            }
            .frame(maxHeight: 130)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpeakerNameRow: View {
    @Environment(TranscriptionModel.self) private var transcription
    let speaker: Speaker
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(speaker.defaultLabel).font(.callout).frame(width: 210, alignment: .leading).lineLimit(1)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { transcription.rename(speaker.key, to: text) }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { transcription.rename(speaker.key, to: text) }   // commit on focus loss
                }
            Button {
                text = ""
                transcription.rename(speaker.key, to: "")
            } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).help("Restore default name")
                .disabled(text.isEmpty && transcription.customName(for: speaker.key).isEmpty)
        }
        .onAppear { text = transcription.customName(for: speaker.key) }
        .onChange(of: transcription.names[speaker.key]) { _, new in
            // keep in sync when renamed via the transcript popover
            if (new ?? "") != text.trimmingCharacters(in: .whitespacesAndNewlines) { text = new ?? "" }
        }
    }
}

/// One-line (wrapping) summary of the recording, max 200 characters; saved to Summary.txt.
private struct SummaryField: View {
    @Environment(TranscriptionModel.self) private var transcription
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Summary").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(text.count) / \(RecordingSummary.maxLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(text.count >= RecordingSummary.maxLength ? Color.red : Color.secondary)
            }
            TextField("Add a short summary…", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { transcription.setSummary(text) }
                .onChange(of: text) { _, new in
                    if new.count > RecordingSummary.maxLength { text = String(new.prefix(RecordingSummary.maxLength)) }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { transcription.setSummary(text) }       // commit on focus loss
                }
        }
        .padding(12)
        .onAppear { text = transcription.summary }
        .onChange(of: transcription.summary) { _, new in if !focused { text = new } }
    }
}
