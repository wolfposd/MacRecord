import CoreAudio
import AudioToolbox
import Foundation
import os

enum SourceKind {
    case processes([AudioObjectID])
    case allSystemAudio
    case microphone(InputDevice)
}

/// One running capture (process tap or input device). Audio goes to a `TrackRecorder`; whenever the
/// capture device's sample rate changes (e.g. a Bluetooth headset switching to call mode) the current
/// file is closed and a new segment file is started at the new rate.
final class CaptureSource: @unchecked Sendable {
    private struct State {
        var segments: [TrackRecorder] = []
        var nextIndex = 1
        var error: String?
    }

    private let kind: SourceKind
    private let requestedChannels: Int
    private let baseURL: URL                  // `<dir>/<name>` without extension
    private let deviceID: AudioObjectID       // aggregate (taps) or the input device itself (mic)
    private let tapID: AudioObjectID?
    private let aggregateID: AudioObjectID?
    private let rateWatch: [AudioObjectID]    // objects whose nominal rate we observe
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "MacRecord.capture")
    private var procID: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?
    private var running = false
    private var stopped = false

    private init(
        kind: SourceKind, requestedChannels: Int, baseURL: URL, deviceID: AudioObjectID,
        tapID: AudioObjectID?, aggregateID: AudioObjectID?, rateWatch: [AudioObjectID]
    ) {
        self.kind = kind
        self.requestedChannels = requestedChannels
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.rateWatch = rateWatch
    }

    // MARK: Status

    var segments: [TrackRecorder] { state.withLock { $0.segments } }
    var recorder: TrackRecorder { state.withLock { $0.segments.last! } }
    var errorText: String? { state.withLock { $0.error } ?? segments.compactMap(\.errorText).first }

    // MARK: Creation

    /// `url` is the first segment's file; later segments get " – part N" appended before the extension.
    static func make(kind: SourceKind, channels requested: Int, url: URL) throws -> CaptureSource {
        let base = url.deletingPathExtension()
        switch kind {
        case .microphone(let device):
            let source = CaptureSource(
                kind: kind, requestedChannels: requested, baseURL: base, deviceID: device.deviceID,
                tapID: nil, aggregateID: nil, rateWatch: [device.deviceID])
            try source.begin()
            return source

        case .processes, .allSystemAudio:
            return try makeTap(kind: kind, requested: requested, base: base)
        }
    }

    private static func makeTap(kind: SourceKind, requested: Int, base: URL) throws -> CaptureSource {
        let mono = requested == 1
        let description: CATapDescription
        switch kind {
        case .processes(let objects):
            description = mono
                ? CATapDescription(monoMixdownOfProcesses: objects)
                : CATapDescription(stereoMixdownOfProcesses: objects)
        default:
            let own = AudioObjectID.processObject(forPID: getpid()).map { [$0] } ?? []
            description = mono
                ? CATapDescription(monoGlobalTapButExcludeProcesses: own)
                : CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.name = "MacRecord tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted        // keep playing through the speakers

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap")
        var aggregateID = AudioObjectID(kAudioObjectUnknown)

        func cleanup() {
            if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
            AudioHardwareDestroyProcessTap(tapID)
        }

        do {
            let outputDevice = try AudioObjectID.systemObject.get(
                kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self)
            guard let outputUID = outputDevice.getString(kAudioDevicePropertyDeviceUID) else {
                throw AudioError.message("No audio output device available")
            }

            let dictionary: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacRecord \(description.uuid.uuidString.prefix(8))",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregateID),
                      "Creating aggregate device")

            let source = CaptureSource(
                kind: kind, requestedChannels: requested, baseURL: base, deviceID: aggregateID,
                tapID: tapID, aggregateID: aggregateID, rateWatch: [aggregateID, outputDevice])
            try source.begin()
            return source
        } catch {
            cleanup()
            throw error
        }
    }

    // MARK: Segments

    private func currentRate() -> Double? {
        // Audio arrives at the capture device's clock rate, which for a tap follows the output device
        // and can differ from the tap's own reported format.
        for object in [deviceID] + rateWatch {
            if let rate = try? object.get(kAudioDevicePropertyNominalSampleRate, as: Float64.self), rate > 0 {
                return rate
            }
        }
        return nil
    }

    private func currentChannels() throws -> Int {
        switch kind {
        case .microphone(let device):
            let available = max(1, deviceID.inputChannelCount())
            _ = device
            return max(1, min(requestedChannels, available))
        default:
            let format = try tapID!.get(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
            return max(1, min(requestedChannels, Int(format.mChannelsPerFrame)))
        }
    }

    private func makeSegment(rate: Double) throws -> TrackRecorder {
        let index = state.withLock { s -> Int in defer { s.nextIndex += 1 }; return s.nextIndex }
        let url = index == 1
            ? baseURL.appendingPathExtension("caf")
            : baseURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseURL.lastPathComponent) – part \(index).caf")
        let recorder = try TrackRecorder(url: url, sampleRate: rate, channels: try currentChannels())
        state.withLock { $0.segments.append(recorder) }
        return recorder
    }

    private func installProc(for recorder: TrackRecorder) throws {
        var newProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, deviceID, nil) { _, input, inputTime, _, _ in
            recorder.push(input, hostTime: inputTime.pointee.mHostTime)
        }
        guard status == noErr, let newProc else { throw AudioError.status(status, "Creating IO proc") }
        procID = newProc
    }

    /// Creates the first segment and IO proc (not yet started).
    private func begin() throws {
        guard let rate = currentRate() else { throw AudioError.message("Could not read the audio device's sample rate") }
        let first = try makeSegment(rate: rate)
        do { try installProc(for: first) } catch {
            teardownDevices()
            throw error
        }
    }

    func start() throws {
        recorder.startWriting()
        try check(AudioDeviceStart(deviceID, procID), "Starting audio device")
        running = true

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleRateChange() }
        listener = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        for object in rateWatch { AudioObjectAddPropertyListenerBlock(object, &address, queue, block) }
        // A change may have happened between creating the file and registering the listener.
        queue.async { [weak self] in self?.handleRateChange() }
    }

    private func handleRateChange() {          // runs on `queue`
        guard !stopped, running, let rate = currentRate(), rate != recorder.sampleRate else { return }
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        let old = recorder
        old.finish()
        if old.frames == 0 {                   // drop empty segments caused by transient rate flips
            try? FileManager.default.removeItem(at: old.url)
            state.withLock { _ = $0.segments.popLast() }
        }
        do {
            let next = try makeSegment(rate: rate)
            try installProc(for: next)
            next.startWriting()
            try check(AudioDeviceStart(deviceID, procID), "Restarting audio device")
        } catch {
            running = false
            state.withLock { $0.error = "Capture stopped after a sample-rate change: \(error.localizedDescription)" }
        }
    }

    /// Stops capture, flushes everything to disk and tears down tap/aggregate. Idempotent.
    func stop() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if let listener {
            for object in rateWatch { AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener) }
            self.listener = nil
        }
        queue.sync {
            guard !stopped else { return }
            stopped = true
            if let procID {
                if running { AudioDeviceStop(deviceID, procID) }
                AudioDeviceDestroyIOProcID(deviceID, procID)
                self.procID = nil
            }
            running = false
            segments.last?.finish()
            teardownDevices()
        }
    }

    private func teardownDevices() {
        if let aggregateID { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if let tapID { AudioHardwareDestroyProcessTap(tapID) }
    }
}
