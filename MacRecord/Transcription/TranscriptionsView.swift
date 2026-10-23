import SwiftUI

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    let trackCount: Int
    let bytes: Int64
    let hasTranscript: Bool
    let summary: String
    /// Name of the topic subfolder this recording lives in, or nil if it's directly under the storage folder.
    let topic: String?

    var title: String {
        // Folders are named "MacRecord yyyy-MM-dd HH.mm.ss"; fall back to the plain folder name.
        let formatter = DateFormatter()
        formatter.dateFormat = "'MacRecord' yyyy-MM-dd HH.mm.ss"
        guard let parsed = formatter.date(from: url.lastPathComponent) else { return url.lastPathComponent }
        return parsed.formatted(date: .abbreviated, time: .shortened)
    }
}

@MainActor @Observable
final class RecordingsModel {
    private(set) var recordings: [Recording] = []
    /// Names of topic subfolders directly under the storage folder (even empty ones).
    private(set) var topics: [String] = []
    private(set) var isLoading = false

    func reload(in folder: URL?) {
        guard let folder else { recordings = []; topics = []; return }
        isLoading = true
        Task {
            let found = await Task.detached(priority: .utility) { Self.scan(folder) }.value
            recordings = found.recordings
            topics = found.topics
            isLoading = false
        }
    }

    /// A subfolder qualifies as a recording if it contains audio (`.caf`/`.m4a`), a `session.json`, or a transcript.
    private nonisolated static func recording(at url: URL, topic: String?, keys: [URLResourceKey]) -> Recording? {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let audio = files.filter { ["caf", "m4a"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
        let hasSession = files.contains { $0.lastPathComponent == "session.json" }
        guard !audio.isEmpty || hasSession || files.contains(where: { $0.lastPathComponent.hasPrefix("Transcript.") }) else { return nil }
        let bytes = audio.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let values = try? url.resourceValues(forKeys: Set(keys))
        let names = Set(files.map(\.lastPathComponent))
        return Recording(
            url: url,
            date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
            trackCount: audio.count, bytes: bytes,
            hasTranscript: names.contains("Transcript.json") || names.contains("Transcript.txt"),
            summary: names.contains("Summary.txt") ? RecordingSummary.read(in: url) : "",
            topic: topic)
    }

    /// Immediate subfolders are either recordings, or topic folders whose own immediate subfolders are recordings.
    private nonisolated static func scan(_ folder: URL) -> (recordings: [Recording], topics: [String]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return ([], []) }
        var found: [Recording] = []
        var topics: [String] = []
        for url in children {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let top = recording(at: url, topic: nil, keys: keys) {
                found.append(top)
                continue
            }
            let topicName = url.lastPathComponent
            topics.append(topicName)
            guard let grandchildren = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { continue }
            for child in grandchildren {
                if let nested = recording(at: child, topic: topicName, keys: keys) { found.append(nested) }
            }
        }
        return (found.sorted { $0.date > $1.date }, topics)
    }
}

/// Which recordings the detail list shows.
private enum TopicFilter: Hashable {
    case all, uncategorized, topic(String)
}

/// A pending "enter a topic name" prompt: creating a topic, renaming one, or creating one on the fly while moving a recording.
private enum TopicPrompt: Identifiable {
    case newTopic
    case renameTopic(String)
    case moveToNewTopic(Recording)

    var id: String {
        switch self {
        case .newTopic: "new"
        case .renameTopic(let name): "rename:\(name)"
        case .moveToNewTopic(let recording): "moveNew:\(recording.id)"
        }
    }

    var title: String {
        switch self {
        case .newTopic, .moveToNewTopic: "New Topic"
        case .renameTopic: "Rename Topic"
        }
    }

    var initialName: String {
        if case .renameTopic(let name) = self { return name }
        return ""
    }
}

struct TranscriptionsView: View {
    @Environment(RecorderModel.self) private var model
    @Environment(\.transcribeActions) private var transcribeActions
    @Environment(AppNavigation.self) private var nav
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(ConversionModel.self) private var conversion
    @State private var list = RecordingsModel()
    @State private var selectedTopic: TopicFilter = .all
    @State private var editing: Recording?
    @State private var removing: Recording?
    @State private var deleting: Recording?
    @State private var deletingTopic: String?
    @State private var topicPrompt: TopicPrompt?
    @State private var removeError: String?
    @State private var dropTarget: TopicFilter?

    private var filteredRecordings: [Recording] {
        switch selectedTopic {
        case .all: list.recordings
        case .uncategorized: list.recordings.filter { $0.topic == nil }
        case .topic(let name): list.recordings.filter { $0.topic == name }
        }
    }

    var body: some View {
        Group {
            if model.outputFolder == nil {
                ContentUnavailableView {
                    Label("No storage folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Choose the folder your recordings are stored in.")
                } actions: {
                    Button("Open Settings…") { nav.selection = .storage }
                }
            } else if list.recordings.isEmpty && list.topics.isEmpty {
                ContentUnavailableView(
                    list.isLoading ? "Loading…" : "No recordings yet", systemImage: "waveform",
                    description: Text(list.isLoading ? "" : "Recordings you make appear here."))
            } else {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 170)
                    Divider()
                    detailList
                }
            }
        }
        .navigationTitle("Transcriptions")
        .toolbar {
            ToolbarItemGroup {
                Button { topicPrompt = .newTopic } label: { Label("New Topic", systemImage: "folder.badge.plus") }
                    .help("Create a new topic to group recordings in")
                Button { transcribeActions.chooseFolder() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Copy a recording folder into the storage folder and open it")
                Button { list.reload(in: model.outputFolder) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look for new recordings")
            }
        }
        .confirmationDialog("Remove the audio files?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { recording in
            Button("Remove Audio", role: .destructive) { removeAudio(of: recording) }
            Button("Cancel", role: .cancel) {}
        } message: { recording in
            Text("The audio of \(recording.title) is deleted permanently. The transcript is kept, but the transcription can no longer be redone.")
        }
        .confirmationDialog("Delete this recording?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { recording in
            Button("Delete Recording", role: .destructive) { delete(recording) }
            Button("Cancel", role: .cancel) {}
        } message: { recording in
            Text("The folder of \(recording.title) is deleted permanently, including its audio, transcript, summary and all other files. This cannot be undone.")
        }
        .confirmationDialog("Delete this topic?", isPresented: Binding(
            get: { deletingTopic != nil }, set: { if !$0 { deletingTopic = nil } }), presenting: deletingTopic
        ) { name in
            Button("Delete Topic", role: .destructive) { deleteTopic(name) }
            Button("Cancel", role: .cancel) {}
        } message: { name in
            Text("The empty topic folder \"\(name)\" is deleted permanently.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { removeError != nil }, set: { if !$0 { removeError = nil } })
        ) {
            Button("OK") {}
        } message: { Text(removeError ?? "") }
        .sheet(item: $editing) { recording in
            SummarySheet(recording: recording) {
                list.reload(in: model.outputFolder)
                if transcription.folder == recording.url { transcription.refreshSummary() }
            }
        }
        .sheet(item: $topicPrompt) { prompt in
            TopicNameSheet(title: prompt.title, initialName: prompt.initialName) { name in
                handle(prompt, name: name)
            }
        }
        .onAppear { list.reload(in: model.outputFolder) }
        .onChange(of: model.outputFolder) { list.reload(in: model.outputFolder) }
        .onChange(of: nav.libraryVersion) { list.reload(in: model.outputFolder) }
        .onChange(of: conversion.finishedRuns) { list.reload(in: model.outputFolder) }
        .onChange(of: model.isRecording) { if !model.isRecording { list.reload(in: model.outputFolder) } }
    }

    private var sidebar: some View {
        List(selection: $selectedTopic) {
            Label("All Recordings (\(list.recordings.count))", systemImage: "tray.full").tag(TopicFilter.all)
            dropRow(.uncategorized) {
                Label("Uncategorized (\(list.recordings.filter { $0.topic == nil }.count))", systemImage: "questionmark.folder")
            } onDrop: { move($0, toTopic: nil) }
            if !list.topics.isEmpty {
                Section("Topics") {
                    ForEach(list.topics.sorted(), id: \.self) { name in
                        let count = list.recordings.filter { $0.topic == name }.count
                        dropRow(.topic(name)) {
                            Label("\(name) (\(count))", systemImage: "folder")
                                .contextMenu {
                                    Button("Rename…") { topicPrompt = .renameTopic(name) }
                                    Button("Delete", role: .destructive) { deletingTopic = name }
                                        .disabled(count > 0)
                                }
                        } onDrop: { move($0, toTopic: name) }
                    }
                }
            }
        }
    }

    /// A sidebar row that accepts a dragged recording and highlights while one is hovering over it.
    private func dropRow(
        _ filter: TopicFilter, @ViewBuilder label: () -> some View, onDrop: @escaping (Recording) -> Void
    ) -> some View {
        label()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(filter)
            .listRowBackground(dropTarget == filter ? Color.accentColor.opacity(0.15) : nil)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let recording = list.recordings.first(where: { $0.url == url }) else { return false }
                onDrop(recording)
                return true
            } isTargeted: { targeted in
                dropTarget = targeted ? filter : (dropTarget == filter ? nil : dropTarget)
            }
    }

    private var detailList: some View {
        List(filteredRecordings) { recording in
            // The icons/text inside RecordingRow can otherwise claim the click/drag before it starts; a
            // transparent layer stacked on top owns tap and drag uniformly across the whole row instead.
            ZStack {
                RecordingRow(recording: recording).allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .draggable(recording.url) { RecordingRow(recording: recording).frame(width: 260) }
                    .simultaneousGesture(TapGesture().onEnded { transcribeActions.open(recording.url) })
            }
            .listRowSeparator(.visible)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            .contextMenu {
                    Button(recording.hasTranscript ? "Open Transcript" : "Transcribe…") {
                        transcribeActions.open(recording.url)
                    }
                    Button("Edit Summary…") { editing = recording }
                    Menu("Move to Topic") {
                        if recording.topic != nil {
                            Button("Uncategorized") { move(recording, toTopic: nil) }
                        }
                        ForEach(list.topics.sorted(), id: \.self) { name in
                            if recording.topic != name {
                                Button(name) { move(recording, toTopic: name) }
                            }
                        }
                        Divider()
                        Button("New Topic…") { topicPrompt = .moveToNewTopic(recording) }
                    }
                    .disabled(busy(recording))
                    Button("Remove Audio…", role: .destructive) { removing = recording }
                        .disabled(recording.trackCount == 0 || busy(recording))
                    Button("Delete…", role: .destructive) { deleting = recording }
                        .disabled(busy(recording))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                }
        }
    }
}

extension TranscriptionsView {
    /// True while the recording is being transcribed or compressed.
    fileprivate func busy(_ recording: Recording) -> Bool {
        (transcription.folder == recording.url && transcription.isWorking)
            || (conversion.isRunning && conversion.activeFolder == recording.url)
    }

    fileprivate func delete(_ recording: Recording) {
        guard !busy(recording) else { return }
        let folder = recording.url
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.removeItem(at: folder)
            transcription.unload(folder: folder)
        } catch {
            removeError = "Could not delete the recording: \(error.localizedDescription)"
        }
        list.reload(in: model.outputFolder)
    }

    fileprivate func removeAudio(of recording: Recording) {
        guard !busy(recording) else { return }
        let folder = recording.url
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["caf", "m4a"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
        var failed: [String] = []
        for file in files {
            do { try FileManager.default.removeItem(at: file) } catch { failed.append(file.lastPathComponent) }
        }
        if transcription.folder == folder { transcription.refreshAudio() }
        list.reload(in: model.outputFolder)
        if !failed.isEmpty { removeError = "Could not delete: \(failed.joined(separator: ", "))" }
    }

    /// Moves a recording folder into (or out of, for `topic == nil`) a topic subfolder of the storage folder.
    fileprivate func move(_ recording: Recording, toTopic topic: String?) {
        guard !busy(recording), let outputFolder = model.outputFolder else { return }
        let folder = recording.url
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let destinationParent = topic.map { outputFolder.appendingPathComponent($0) } ?? outputFolder
        if topic != nil && !fm.fileExists(atPath: destinationParent.path) {
            try? fm.createDirectory(at: destinationParent, withIntermediateDirectories: false)
        }
        let name = folder.lastPathComponent
        var target = destinationParent.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = destinationParent.appendingPathComponent("\(name) \(n)")
            n += 1
        }
        do {
            try fm.moveItem(at: folder, to: target)
            if transcription.folder == folder { transcription.unload(folder: folder) }
        } catch {
            removeError = "Could not move the recording: \(error.localizedDescription)"
        }
        list.reload(in: model.outputFolder)
    }

    fileprivate func handle(_ prompt: TopicPrompt, name: String) {
        switch prompt {
        case .newTopic:
            createTopic(named: name)
        case .renameTopic(let oldName):
            renameTopic(oldName, to: name)
        case .moveToNewTopic(let recording):
            createTopic(named: name)
            move(recording, toTopic: name)
        }
    }

    fileprivate func createTopic(named name: String) {
        guard let outputFolder = model.outputFolder else { return }
        let scoped = outputFolder.startAccessingSecurityScopedResource()
        defer { if scoped { outputFolder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(
                at: outputFolder.appendingPathComponent(name), withIntermediateDirectories: false)
            selectedTopic = .topic(name)
        } catch {
            removeError = "Could not create the topic: \(error.localizedDescription)"
        }
        list.reload(in: model.outputFolder)
    }

    fileprivate func renameTopic(_ name: String, to newName: String) {
        guard let outputFolder = model.outputFolder else { return }
        let scoped = outputFolder.startAccessingSecurityScopedResource()
        defer { if scoped { outputFolder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.moveItem(
                at: outputFolder.appendingPathComponent(name), to: outputFolder.appendingPathComponent(newName))
            if selectedTopic == .topic(name) { selectedTopic = .topic(newName) }
        } catch {
            removeError = "Could not rename the topic: \(error.localizedDescription)"
        }
        list.reload(in: model.outputFolder)
    }

    fileprivate func deleteTopic(_ name: String) {
        guard let outputFolder = model.outputFolder else { return }
        let scoped = outputFolder.startAccessingSecurityScopedResource()
        defer { if scoped { outputFolder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.removeItem(at: outputFolder.appendingPathComponent(name))
            if selectedTopic == .topic(name) { selectedTopic = .all }
        } catch {
            removeError = "Could not delete the topic: \(error.localizedDescription)"
        }
        list.reload(in: model.outputFolder)
    }
}

private struct TopicNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialName: String
    let onConfirm: (String) -> Void
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Topic name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("OK", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { name = initialName }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { error = "Enter a name."; return }
        onConfirm(trimmed)
        dismiss()
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: recording.trackCount == 0 ? "music.note.slash" : "music.note")
                        .foregroundStyle(.secondary)
                    Text(recording.title).font(.headline)
                }
                if recording.trackCount > 0 {
                    Text("\(recording.trackCount) track\(recording.trackCount == 1 ? "" : "s") · "
                         + ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !recording.summary.isEmpty {
                    Text(recording.summary).font(.callout).lineLimit(2).padding(.top, 2)
                }
            }
            Spacer()
            if recording.hasTranscript {
                Label("Transcript", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("Not transcribed").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct SummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let recording: Recording
    let onSaved: () -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
            Text(recording.title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: text) { _, new in
                    if new.count > RecordingSummary.maxLength { text = String(new.prefix(RecordingSummary.maxLength)) }
                }
            HStack {
                Text("\(text.count) / \(RecordingSummary.maxLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(text.count >= RecordingSummary.maxLength ? Color.red : Color.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    do {
                        try RecordingSummary.write(text, in: recording.url)
                        onSaved()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { text = recording.summary }
    }
}
