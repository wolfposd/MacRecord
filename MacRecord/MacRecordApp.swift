import SwiftUI

@main
struct MacRecordApp: App {
    @State private var model = RecorderModel()
    @State private var models = WhisperModelStore()
    @State private var transcription = TranscriptionModel()
    @State private var ai = AIConfigStore()
    @State private var chat = AIChatModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(models)
                .environment(transcription)
        }
        .windowResizability(.contentMinSize)

        Window("Transcript", id: "transcript") {
            TranscriptView()
                .environment(transcription)
                .environment(models)
        }

        Window("AI Chat", id: "ai-chat") {
            AIChatView()
                .environment(ai)
                .environment(transcription)
                .environment(chat)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(models)
                .environment(ai)
        }
    }
}
