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

/// Which page the main window shows; shared so other views and the ⌘, command can navigate.
@MainActor @Observable
final class AppNavigation {
    enum Page: String, Identifiable {
        case record = "Record", transcriptions = "Transcriptions"           // section "General"
        case storage = "Storage", recording = "Recording", transcript = "Transcript", ai = "AI"   // section "Settings"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .record: "record.circle"
            case .transcriptions: "text.bubble"
            case .storage: "folder"
            case .recording: "waveform"
            case .transcript: "waveform.and.magnifyingglass"
            case .ai: "sparkles"
            }
        }
    }

    var selection: Page? = .record
    /// Bumped when recording folders were added from outside, so lists reload.
    var libraryVersion = 0
}

struct RootView: View {
    @Environment(RecorderModel.self) private var model
    @Environment(WhisperModelStore.self) private var models
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(ConversionModel.self) private var conversion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @Environment(AppNavigation.self) private var nav

    @State private var showPicker = false
    @State private var noModelAlert = false
    @State private var isImporting = false

    var body: some View {
        @Bindable var nav = nav
        return NavigationSplitView {
            List(selection: $nav.selection) {
                Section("General") {
                    row(.record)
                    row(.transcriptions)
                }
                Section("Settings") {
                    row(.storage)
                    row(.recording)
                    row(.transcript)
                    row(.ai)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch nav.selection ?? .record {
            case .record: RecordView()
            case .transcriptions: TranscriptionsView()
            case .storage: StorageSettingsView()
            case .recording: RecordingSettingsView()
            case .transcript: TranscriptSettingsView()
            case .ai: AISettingsView()
            }
        }
        .frame(minWidth: 420, minHeight: 540)
        .environment(\.transcribeActions, TranscribeActions(open: open, chooseFolder: { showPicker = true }))
        .task { await model.run() }
        .onChange(of: model.isRecording) { wasRecording, isRecording in
            if isRecording {
                conversion.clearResult()
                openWindow(id: "mini")
                hideMainWindow()
            } else if wasRecording, conversion.convertToAAC, let folder = model.sessionFolder {
                conversion.start(folder: folder, files: model.lastTrackFiles)
            }
            if wasRecording && !isRecording {
                dismissWindow(id: "mini")
                openWindow(id: "main")
                mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
        // One importer for the whole window: SwiftUI honours only one `.fileImporter` per view.
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { importFolder(url) }
        }
        .fileDialogDefaultDirectory(model.sessionFolder ?? model.outputFolder)
        .overlay {
            if isImporting {
                ProgressView("Importing…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
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

    /// The main window is only hidden (not closed), so this view keeps driving the recorder's meters and timer.
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    private func hideMainWindow() { mainWindow?.orderOut(nil) }

    private func row(_ page: AppNavigation.Page) -> some View {
        Label(page.rawValue, systemImage: page.icon).tag(page)
    }

    /// Copies a recording folder into the storage folder, then opens the copy (transcribing it if needed).
    private func importFolder(_ source: URL) {
        guard let storage = model.outputFolder else {
            model.errorMessage = "Choose a storage folder in Settings first."
            return
        }
        let name = source.lastPathComponent
        // Already inside the storage folder: nothing to copy.
        if source.deletingLastPathComponent().standardizedFileURL == storage.standardizedFileURL {
            open(source)
            return
        }
        isImporting = true
        Task {
            let scoped = source.startAccessingSecurityScopedResource()
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var target = storage.appendingPathComponent(name)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = storage.appendingPathComponent("\(name) \(n)")
                    n += 1
                }
                do {
                    try fm.copyItem(at: source, to: target)
                    return .success(target)
                } catch {
                    try? fm.removeItem(at: target)      // no half-copied folder
                    return .failure(error)
                }
            }.value
            if scoped { source.stopAccessingSecurityScopedResource() }
            isImporting = false
            switch result {
            case .success(let copy):
                nav.libraryVersion += 1
                open(copy)
            case .failure(let error):
                model.errorMessage = "Could not import the folder: \(error.localizedDescription)"
            }
        }
    }

    private func open(_ url: URL) {
        if conversion.isRunning, conversion.activeFolder == url { return }     // audio is still being converted
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
