import SwiftUI

struct Recording: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    let trackCount: Int
    let bytes: Int64
    let hasTranscript: Bool

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

    /// Immediate subfolders that contain audio (`.caf`) or a `session.json`, newest first.
    private nonisolated static func scan(_ folder: URL) -> [Recording] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return children.compactMap { url -> Recording? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
            let audio = files.filter { $0.pathExtension.lowercased() == "caf" }
            let hasSession = files.contains { $0.lastPathComponent == "session.json" }
            guard !audio.isEmpty || hasSession else { return nil }
            let bytes = audio.reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let names = Set(files.map(\.lastPathComponent))
            return Recording(
                url: url,
                date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                trackCount: audio.count, bytes: bytes,
                hasTranscript: names.contains("Transcript.json") || names.contains("Transcript.txt"))
        }
        .sorted { $0.date > $1.date }
    }
}

struct TranscriptionsView: View {
    @Environment(RecorderModel.self) private var model
    @Environment(\.transcribeActions) private var transcribeActions
    @Environment(\.openSettings) private var openSettings
    @State private var list = RecordingsModel()

    var body: some View {
        Group {
            if model.outputFolder == nil {
                ContentUnavailableView {
                    Label("No storage folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Choose the folder your recordings are stored in.")
                } actions: {
                    Button("Open Settings…") { openSettings() }
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
                            Button(recording.hasTranscript ? "Open / Re-transcribe…" : "Transcribe…") {
                                transcribeActions.open(recording.url)
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                        }
                }
            }
        }
        .navigationTitle("Transcriptions")
        .toolbar {
            ToolbarItemGroup {
                Button { transcribeActions.chooseFolder() } label: { Label("Other Folder…", systemImage: "folder") }
                    .help("Transcribe a recording folder from somewhere else")
                Button { list.reload(in: model.outputFolder) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look for new recordings")
            }
        }
        .onAppear { list.reload(in: model.outputFolder) }
        .onChange(of: model.outputFolder) { list.reload(in: model.outputFolder) }
        .onChange(of: model.isRecording) { if !model.isRecording { list.reload(in: model.outputFolder) } }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(.headline)
                Text("\(recording.trackCount) track\(recording.trackCount == 1 ? "" : "s") · "
                     + ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
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
