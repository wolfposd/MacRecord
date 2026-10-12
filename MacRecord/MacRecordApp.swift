import AppKit
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
            // The standard macOS About panel (icon, name, version) with a link to the project in its credits.
            CommandGroup(replacing: .appInfo) {
                Button("About MacRecord") { Self.showAbout() }
            }
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

    private static let repositoryURL = URL(string: "https://github.com/wolfposd/MacRecord")!

    private static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Records system audio per app and\n transcribes it locally.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "github.com/wolfposd/MacRecord",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repositoryURL]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
