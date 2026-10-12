import AVFoundation
import Observation

/// Plays a short range of a recording's audio file (one transcript line).
@Observable @MainActor
final class ClipPlayer {
    private(set) var playingID: UUID?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    private var scopedFolder: URL?

    func toggle(id: UUID, url: URL, start: Double, end: Double, folder: URL?) {
        if playingID == id { stop(); return }
        stop()
        if let folder, folder.startAccessingSecurityScopedResource() { scopedFolder = folder }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { stop(); return }
        player.currentTime = start
        guard player.play() else { stop(); return }
        self.player = player
        playingID = id
        stopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let p = self.player else { return }
                if !p.isPlaying || p.currentTime >= end { self.stop(); return }
            }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingID = nil
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }
}
