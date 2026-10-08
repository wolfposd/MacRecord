import AppKit
import AVFoundation
import CoreAudio
import Observation

struct SessionInfo: Codable {
    struct Track: Codable {
        var file: String
        var source: String
        var sampleRate: Double
        var channels: Int
        var startOffsetSeconds: Double?     // first captured buffer relative to the earliest track
        var frames: Int?
        var droppedFrames: Int?
    }
    var startedAt: Date
    var endedAt: Date?
    var format = "CAF, 32-bit float PCM, interleaved"
    var tracks: [Track]
}

@MainActor @Observable
final class RecorderModel {
    static let systemKey = "system"
    static let micKey = "mic"

    // Catalogs
    private(set) var apps: [AudioApp] = []
    private(set) var inputDevices: [InputDevice] = []

    // Selection
    var selectedApps: Set<String> = []
    var recordSystemAudio = false
    var recordMic = false
    var micDeviceUID: String?
    var channelChoice: [String: Int] = [:]      // source key -> 1 (mono) / 2 (stereo)

    // Output
    private(set) var outputFolder: URL?
    private(set) var sessionFolder: URL?

    // Run state
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [String: Float] = [:]
    private(set) var bytes: [String: Int] = [:]
    var errorMessage: String?

    private struct Active {
        let key: String
        let name: String
        let file: String
        let capture: CaptureSource
    }
    private var active: [Active] = []
    private var startDate = Date()
    private var session: SessionInfo?
    private var scopedFolder: URL?
    private var activity: NSObjectProtocol?
    private var tick = 0
    private var knownSegments = 0

    private static let bookmarkKey = "outputFolderBookmark"

    init() {
        restoreFolder()
        refreshCatalogs()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stopRecording() } }
    }

    // MARK: Derived

    func channels(for key: String, default value: Int) -> Int { channelChoice[key] ?? value }

    var selectedMic: InputDevice? { inputDevices.first { $0.id == micDeviceUID } }

    var sourceCount: Int {
        selectedApps.count + (recordSystemAudio ? 1 : 0) + (recordMic && selectedMic != nil ? 1 : 0)
    }

    var canRecord: Bool { isRecording || (outputFolder != nil && sourceCount > 0) }

    var totalBytes: Int { bytes.values.reduce(0, +) }

    // MARK: Catalog refresh / ticking

    func refreshCatalogs() {
        guard !isRecording else { return }
        apps = ProcessCatalog.snapshot()
        inputDevices = InputDeviceCatalog.snapshot()
        if selectedMic == nil { micDeviceUID = InputDeviceCatalog.defaultDeviceUID() ?? inputDevices.first?.id }
    }

    /// Drives live meters, elapsed time and catalog refresh. Run from the view's `.task`.
    func run() async {
        while !Task.isCancelled {
            tick += 1
            if isRecording {
                elapsed = Date().timeIntervalSince(startDate)
                for item in active {
                    let peak = item.capture.recorder.takePeak()
                    levels[item.key] = max(peak, (levels[item.key] ?? 0) * 0.8)
                    bytes[item.key] = item.capture.segments.reduce(0) { $0 + $1.bytesWritten }
                    if let text = item.capture.errorText, errorMessage == nil {
                        errorMessage = "Writing \(item.file) failed: \(text)"
                    }
                }
                let segmentCount = active.reduce(0) { $0 + $1.capture.segments.count }
                if segmentCount != knownSegments { writeSession() }
            } else if tick % 20 == 0 {
                refreshCatalogs()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Output folder

    /// Access to the storage folder is held for the app's lifetime (not just while recording), because
    /// listing recordings and opening a recording's subfolder only work while the parent's scope is active.
    private func beginAccess(to url: URL) {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
    }

    func setOutputFolder(_ url: URL) {
        beginAccess(to: url)
        do {
            let data = try url.bookmarkData(options: .withSecurityScope)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            errorMessage = "The folder was selected but could not be remembered for next launch: \(error.localizedDescription)"
        }
        outputFolder = url
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
            beginAccess(to: url)
            outputFolder = url
        }
    }

    // MARK: Recording

    func toggleRecording() async {
        if isRecording { stopRecording() } else { await startRecording() }
    }

    func startRecording() async {
        guard !isRecording, let folder = outputFolder else { return }
        errorMessage = nil
        refreshCatalogs()

        if recordMic, selectedMic != nil {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                errorMessage = "Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone."
                return
            }
        }

        guard scopedFolder != nil else {
            errorMessage = "Cannot access the storage folder. Please choose it again in Settings."
            return
        }

        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let dir = folder.appendingPathComponent("MacRecord \(formatter.string(from: Date()))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            sessionFolder = dir

            var plan: [(key: String, name: String, kind: SourceKind, channels: Int)] = []
            if recordSystemAudio {
                plan.append((Self.systemKey, "All System Audio", .allSystemAudio, channels(for: Self.systemKey, default: 2)))
            }
            for app in apps where selectedApps.contains(app.id) {
                plan.append((app.id, app.name, .processes(app.processObjects), channels(for: app.id, default: 2)))
            }
            if recordMic, let mic = selectedMic {
                plan.append((Self.micKey, "Microphone – \(mic.name)", .microphone(mic), channels(for: Self.micKey, default: 1)))
            }
            guard !plan.isEmpty else { throw AudioError.message("Nothing selected to record.") }

            var used = Set<String>()
            var created: [Active] = []
            do {
                for item in plan {
                    let file = Self.uniqueFileName(item.name, used: &used)
                    let capture = try CaptureSource.make(
                        kind: item.kind, channels: item.channels, url: dir.appendingPathComponent(file))
                    created.append(Active(key: item.key, name: item.name, file: file, capture: capture))
                }
                startDate = Date()
                for item in created { try item.capture.start() }
            } catch {
                created.forEach { $0.capture.stop() }
                throw error
            }

            active = created
            session = SessionInfo(startedAt: startDate, tracks: [])
            writeSession()
            levels = [:]
            bytes = [:]
            elapsed = 0
            isRecording = true
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording audio")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        for item in active { item.capture.stop() }

        session?.endedAt = Date()
        if active.contains(where: { $0.capture.segments.contains { $0.dropped > 0 } }) {
            errorMessage = "Some audio was dropped because the disk could not keep up (see session.json)."
        }
        writeSession()

        active = []
        levels = [:]
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func revealSession() {
        if let url = sessionFolder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Helpers

    private func writeSession() {
        guard var session, let dir = sessionFolder else { return }
        let all = active.flatMap { item in item.capture.segments.map { (item, $0) } }
        knownSegments = all.count
        let earliest = all.compactMap { $0.1.firstHostTime }.min()
        session.tracks = all.map { item, recorder in
            var offset: Double?
            if let first = recorder.firstHostTime, let earliest {
                offset = Double(AudioConvertHostTimeToNanos(first) - AudioConvertHostTimeToNanos(earliest)) / 1e9
            }
            return .init(file: recorder.url.lastPathComponent, source: item.name,
                         sampleRate: recorder.sampleRate, channels: recorder.channels,
                         startOffsetSeconds: offset, frames: recorder.frames, droppedFrames: recorder.dropped)
        }
        self.session = session
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(session).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }

    private static func uniqueFileName(_ name: String, used: inout Set<String>) -> String {
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = "\(base).caf"
        var n = 2
        while !used.insert(candidate.lowercased()).inserted {
            candidate = "\(base) \(n).caf"
            n += 1
        }
        return candidate
    }
}
