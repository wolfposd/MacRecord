import SwiftUI
import UniformTypeIdentifiers

/// What the pages can ask the shell to do, so the transcribe flow lives in one place.
struct TranscribeActions {
    /// Open a recording folder: shows an existing transcript (after asking) or transcribes it.
    var open: (URL) -> Void = { _ in }
    /// Let the user pick any recording folder (also outside the storage folder).
    var chooseFolder: () -> Void = {}
}

private struct TranscribeActionsKey: EnvironmentKey { static let defaultValue = TranscribeActions() }

extension EnvironmentValues {
    var transcribeActions: TranscribeActions {
        get { self[TranscribeActionsKey.self] }
        set { self[TranscribeActionsKey.self] = newValue }
    }
}

struct RootView: View {
    @Environment(RecorderModel.self) private var model
    @Environment(WhisperModelStore.self) private var models
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(\.openWindow) private var openWindow

    private enum Page: String, CaseIterable, Identifiable {
        case record = "Record"
        case transcriptions = "Transcriptions"
        var id: String { rawValue }
        var icon: String { self == .record ? "record.circle" : "text.bubble" }
    }

    @State private var page: Page? = .record
    @State private var showPicker = false
    @State private var noModelAlert = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch page ?? .record {
            case .record: RecordView()
            case .transcriptions: TranscriptionsView()
            }
        }
        .frame(minWidth: 420, minHeight: 540)
        .environment(\.transcribeActions, TranscribeActions(open: open, chooseFolder: { showPicker = true }))
        .task { await model.run() }
        // One importer for the whole window: SwiftUI honours only one `.fileImporter` per view.
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { open(url) }
        }
        .fileDialogDefaultDirectory(model.sessionFolder ?? model.outputFolder)
        .alert("No transcription model", isPresented: $noModelAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Download a Whisper model in Settings (⌘,) first.")
        }
        .alert("MacRecord", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func open(_ url: URL) {
        if transcription.isWorking {
            openWindow(id: "transcript")        // a run is in progress; just bring its window forward
        } else if TranscriptionModel.hasTranscript(in: url) {
            transcription.load(folder: url)
            openWindow(id: "transcript")
        } else {
            transcribe(url)
        }
    }

    private func transcribe(_ folder: URL) {
        guard let id = models.selectedModelID else { noModelAlert = true; return }
        transcription.start(folder: folder, modelID: id, store: models)
        openWindow(id: "transcript")
    }
}
