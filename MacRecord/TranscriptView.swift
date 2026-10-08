import SwiftUI

struct TranscriptView: View {
    @Environment(TranscriptionModel.self) private var transcription

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if transcription.entries.isEmpty {
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
        .frame(minWidth: 560, minHeight: 420)
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
                        if let language = track.language {
                            Text(WhisperModelStore.languageName(language))
                                .font(.caption).foregroundStyle(.secondary)
                        }
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

    private var transcript: some View {
        let sources = Array(Set(transcription.entries.map(\.source))).sorted()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(transcription.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(TranscriptionModel.timestamp(entry.time))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Text(entry.source)
                            .font(.caption.bold())
                            .foregroundStyle(color(for: entry.source, in: sources))
                            .frame(width: 160, alignment: .leading).lineLimit(1)
                        Text(entry.text).textSelection(.enabled)
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

    private var footer: some View {
        HStack {
            switch transcription.phase {
            case .finished:
                Label("Saved Transcript.txt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message) where !transcription.entries.isEmpty:
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
            default:
                EmptyView()
            }
            Spacer()
            if transcription.isWorking {
                Button("Cancel") { transcription.cancel() }
            }
            Button("Copy") {
                let text = transcription.entries
                    .map { "[\(TranscriptionModel.timestamp($0.time))] \($0.source): \($0.text)" }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }.disabled(transcription.entries.isEmpty)
            Button("Show in Finder") {
                if let file = transcription.outputFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }.disabled(transcription.outputFile == nil)
        }
        .padding(12)
    }
}
