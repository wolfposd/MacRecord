import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(RecorderModel.self) private var model
    @Environment(WhisperModelStore.self) private var models
    @Environment(TranscriptionModel.self) private var transcription
    @Environment(\.openWindow) private var openWindow
    private enum FolderPicker { case output, recording }
    // One importer for both uses: SwiftUI honours only one `.fileImporter` per view.
    @State private var showPicker = false
    @State private var pickerMode = FolderPicker.output
    @State private var noModelAlert = false
    @State private var existingFolder: URL?
    @State private var askExisting = false

    var body: some View {
        VStack(spacing: 0) {
            folderBar
            Divider()
            sourceList
            Divider()
            controlBar
        }
        .frame(minWidth: 380, minHeight: 540)
        .task { await model.run() }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            switch pickerMode {
            case .output:
                model.setOutputFolder(url)
            case .recording:
                if TranscriptionModel.hasTranscript(in: url) {
                    existingFolder = url
                    askExisting = true
                } else {
                    transcribe(url)
                }
            }
        }
        .fileDialogDefaultDirectory(model.sessionFolder ?? model.outputFolder)
        .confirmationDialog("This recording already has a transcript", isPresented: $askExisting, presenting: existingFolder) { url in
            Button("Open Existing Transcript") {
                transcription.load(folder: url)
                openWindow(id: "transcript")
            }
            Button("Re-transcribe", role: .destructive) { transcribe(url) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Re-transcribing runs Whisper again and replaces Transcript.txt, including any speaker names you set.")
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

    private func transcribe(_ folder: URL) {
        guard let id = models.selectedModelID else { noModelAlert = true; return }
        transcription.start(folder: folder, modelID: id, store: models)
        openWindow(id: "transcript")
    }

    // MARK: Folder

    private var folderBar: some View {
        HStack {
            Image(systemName: "folder")
            if let folder = model.outputFolder {
                Text(folder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Choose a folder to record into").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { pickerMode = .output; showPicker = true }.disabled(model.isRecording)
        }
        .padding(12)
    }

    // MARK: Sources

    private var sourceList: some View {
        @Bindable var model = model
        return List {
            Section("System") {
                SourceRow(
                    title: "All system audio", systemImage: "speaker.wave.3",
                    isOn: $model.recordSystemAudio,
                    channels: channelBinding(RecorderModel.systemKey, default: 2),
                    level: model.levels[RecorderModel.systemKey],
                    locked: model.isRecording)
            }
            
            Section {
                SourceRow(
                    title: "Microphone", systemImage: "mic",
                    isOn: $model.recordMic,
                    channels: channelBinding(RecorderModel.micKey, default: 1),
                    stereoAvailable: (model.selectedMic?.channels ?? 1) >= 2,
                    level: model.levels[RecorderModel.micKey],
                    locked: model.isRecording)
                Picker("Input device", selection: $model.micDeviceUID) {
                    ForEach(model.inputDevices) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(model.isRecording)
            } header: {
                HStack {
                    Text("Microphone")
                    Spacer()
                    Button("Refresh") { model.refreshCatalogs() }
                        .buttonStyle(.link).disabled(model.isRecording)
                        .help("Look for newly connected input devices")
                }
            }

            Section {
                if model.apps.isEmpty {
                    Text("No apps are using audio right now. Start playback in an app and it will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.apps) { app in
                    SourceRow(
                        title: app.name, iconPath: app.iconPath, badge: app.isPlaying ? "playing" : nil,
                        isOn: Binding(
                            get: { model.selectedApps.contains(app.id) },
                            set: { on in
                                if on { model.selectedApps.insert(app.id) } else { model.selectedApps.remove(app.id) }
                            }),
                        channels: channelBinding(app.id, default: 2),
                        level: model.levels[app.id],
                        locked: model.isRecording)
                }
            } header: {
                HStack {
                    Text("Applications")
                    Spacer()
                    Button("Refresh") { model.refreshCatalogs() }
                        .buttonStyle(.link).disabled(model.isRecording)
                }
            }
            
        }
    }

    private func channelBinding(_ key: String, default value: Int) -> Binding<Int> {
        Binding(
            get: { model.channels(for: key, default: value) },
            set: { model.channelChoice[key] = $0 })
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.toggleRecording() }
            } label: {
                Label(model.isRecording ? "Stop" : "Record",
                      systemImage: model.isRecording ? "stop.fill" : "record.circle")
                    .frame(minWidth: 90)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.canRecord)

            VStack(alignment: .leading) {
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.system(.title3, design: .monospaced))
                if model.isRecording {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.totalBytes), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.outputFolder != nil && model.sourceCount == 0 {
                    Text("Select at least one source").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                pickerMode = .recording
                showPicker = true
            } label: {
                Label("Transcribe…", systemImage: "text.bubble")
            }
            .help("Choose a recording folder to transcribe; Transcript.txt is written into it")
            .disabled(model.isRecording || transcription.isWorking)
            if model.sessionFolder != nil {
                Button("Reveal in Finder") { model.revealSession() }
            }
        }
        .padding(12)
    }
}

struct SourceRow: View {
    let title: String
    var systemImage: String?
    var iconPath: String?
    var badge: String?
    @Binding var isOn: Bool
    @Binding var channels: Int
    var stereoAvailable = true
    var level: Float?
    var locked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn).labelsHidden().disabled(locked)
            Group {
                if let iconPath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath)).resizable()
                } else {
                    Image(systemName: systemImage ?? "waveform").resizable().scaledToFit().padding(3)
                }
            }
            .frame(width: 22, height: 22)

            Text(title).lineLimit(1)
            if let badge {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.green).help("Currently \(badge)")
            }
            Spacer()
            LevelMeter(level: level ?? 0).frame(width: 90, height: 6)
            Picker("", selection: $channels) {
                Text("Mono").tag(1)
                if stereoAvailable { Text("Stereo").tag(2) }
            }
            .labelsHidden().frame(width: 80).disabled(locked)
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let db = 20 * log10(max(level, 1e-5))
            let fraction = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fraction > 0.92 ? Color.red : Color.green)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}
