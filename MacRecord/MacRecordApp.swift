import SwiftUI

@main
struct MacRecordApp: App {
    @State private var model = RecorderModel()
    @State private var models = WhisperModelStore()
    @State private var transcription = TranscriptionModel()
    @State private var ai = AIConfigStore()
    @State private var chat = AIChatModel()
    @State private var nav = AppNavigation()
    @State private var conversion = ConversionModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("MacRecord", id: "main") {
            RootView()
                .environment(model)
                .environment(models)
                .environment(transcription)
                .environment(ai)
                .environment(nav)
                .environment(conversion)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Settings now live in the main window, so ⌘, jumps there instead of opening a second window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    nav.selection = .storage
                    openWindow(id: "main")
                }
                .keyboardShortcut(",")
            }
        }

        Window("Transcript", id: "transcript") {
            TranscriptView()
                .environment(transcription)
                .environment(models)
                .environment(conversion)
        }

        Window("AI Chat", id: "ai-chat") {
            AIChatView()
                .environment(ai)
                .environment(transcription)
                .environment(chat)
        }
    }
}
