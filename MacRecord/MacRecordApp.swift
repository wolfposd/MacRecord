import SwiftUI

@main
struct MacRecordApp: App {
    @State private var model = RecorderModel()
    @State private var models = WhisperModelStore()
    @State private var transcription = TranscriptionModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(models)
                .environment(transcription)
        }
        .windowResizability(.contentMinSize)

        Window("Transcript", id: "transcript") {
            TranscriptView()
                .environment(transcription)
        }

        Settings {
            SettingsView()
                .environment(models)
        }
    }
}
