import SwiftUI

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    let trackCount: Int
    let bytes: Int64
    let hasTranscript: Bool
    let summary: String

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
    private(set) var isLoading = false

    func reload(in folder: URL?) {
        guard let folder else { recordings = []; return }
        isLoading = true
        Task {
            let found = await Task.detached(priority: .utility) { Self.scan(folder) }.value
            recordings = found
            isLoading = false
        }
    }

    /// Immediate subfolders that contain audio (`.caf`/`.m4a`) or a `session.json`, newest first.
    private nonisolated static func scan(_ folder: URL) -> [Recording] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return children.compactMap { url -> Recording? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
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
                summary: names.contains("Summary.txt") ? RecordingSummary.read(in: url) : "")
        }
        .sorted { $0.date > $1.date }
    }
}

struct TranscriptionsView: View {
    @Environment(RecorderModel.self) private var model
    @Environment(\.transcribeActions) private var transcribeActions
    @Environment(AppNavigation.self) private var nav
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(ConversionModel.self) private var conversion
    @State private var list = RecordingsModel()
    @State private var editing: Recording?
    @State private var removing: Recording?
    @State private var deleting: Recording?
    @State private var removeError: String?

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
            } else if list.recordings.isEmpty {
                ContentUnavailableView(
                    list.isLoading ? "Loading…" : "No recordings yet", systemImage: "waveform",
                    description: Text(list.isLoading ? "" : "Recordings you make appear here."))
            } else {
                List(list.recordings) { recording in
                    Button { transcribeActions.open(recording.url) } label: { RecordingRow(recording: recording) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(recording.hasTranscript ? "Open Transcript" : "Transcribe…") {
                                transcribeActions.open(recording.url)
                            }
                            Button("Edit Summary…") { editing = recording }
                            Button("Remove Audio…", role: .destructive) { removing = recording }
                                .disabled(recording.trackCount == 0 || busy(recording))
                            Button("Delete…", role: .destructive) { deleting = recording }
                                .disabled(busy(recording))
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                        }
                }
            }
        }
        .navigationTitle("Transcriptions")
        .toolbar {
            ToolbarItemGroup {
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
        .onAppear { list.reload(in: model.outputFolder) }
        .onChange(of: model.outputFolder) { list.reload(in: model.outputFolder) }
        .onChange(of: nav.libraryVersion) { list.reload(in: model.outputFolder) }
        .onChange(of: conversion.finishedRuns) { list.reload(in: model.outputFolder) }
        .onChange(of: model.isRecording) { if !model.isRecording { list.reload(in: model.outputFolder) } }
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
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(.headline)
                Text(recording.trackCount == 0
                     ? "Audio removed"
                     : "\(recording.trackCount) track\(recording.trackCount == 1 ? "" : "s") · "
                       + ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
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
