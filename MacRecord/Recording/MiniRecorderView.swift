import AppKit
import SwiftUI

/// Compact window shown while recording: elapsed time, Stop, and a live level meter per captured source.
struct MiniRecorderView: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.system(.title2, design: .monospaced))
                Spacer()
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.space, modifiers: [])
            }
            Divider()
            ForEach(model.activeSources, id: \.key) { source in
                HStack(spacing: 8) {
                    Group {
                        if let path = source.iconPath {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
                        } else {
                            Image(systemName: source.key == RecorderModel.micKey ? "mic.fill" : "speaker.wave.2.fill")
                                .resizable().scaledToFit().padding(2)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(source.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    LevelMeter(level: model.levels[source.key] ?? 0).frame(width: 90, height: 6)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
