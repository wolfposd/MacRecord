import AVFoundation
import Synchronization
import os

/// Receives realtime audio via `push` (audio thread, lock-free, no allocation) and
/// continuously appends it to a CAF file from a background queue.
final class TrackRecorder: @unchecked Sendable {
    let url: URL
    let sampleRate: Double
    let channels: Int

    // Single-producer (audio thread) / single-consumer (writer queue) ring of interleaved Float32.
    private let ring: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    private let peakBits = Atomic<UInt32>(0)
    private let framesWritten = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)
    private let firstHost = Atomic<UInt64>(0)
    private let failure = OSAllocatedUnfairLock<String?>(initialState: nil)

    private let queue = DispatchQueue(label: "MacRecord.writer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private let scratch: AVAudioPCMBuffer
    private let scratchFrames = 16_384

    init(url: URL, sampleRate: Double, channels: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        capacity = Int(sampleRate) * channels * 10     // ~10 s of slack for disk stalls
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: true)!
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(scratchFrames))!

        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    deinit { ring.deallocate() }

    // MARK: Audio thread

    func push(_ list: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard abl.count > 0 else { return }
        let interleaved = abl.count == 1
        let inChannels = interleaved ? Int(abl[0].mNumberChannels) : abl.count
        guard inChannels > 0 else { return }
        let frames = Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * (interleaved ? inChannels : 1))
        guard frames > 0 else { return }

        _ = firstHost.compareExchange(expected: 0, desired: hostTime, ordering: .relaxed)

        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let needed = frames * channels
        guard needed <= capacity - (h - t) else {
            _ = droppedFrames.add(frames, ordering: .relaxed)
            return
        }

        var peak: Float = 0
        for f in 0..<frames {
            for c in 0..<channels {
                var sample: Float
                if channels == 1 && inChannels > 1 {
                    sample = 0
                    for ic in 0..<inChannels { sample += Self.sample(abl, interleaved, inChannels, f, ic) }
                    sample /= Float(inChannels)
                } else {
                    sample = Self.sample(abl, interleaved, inChannels, f, min(c, inChannels - 1))
                }
                ring[(h + f * channels + c) % capacity] = sample
                peak = max(peak, abs(sample))
            }
        }
        head.store(h + needed, ordering: .releasing)

        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }
    }

    @inline(__always)
    private static func sample(
        _ abl: UnsafeMutableAudioBufferListPointer, _ interleaved: Bool,
        _ inChannels: Int, _ frame: Int, _ channel: Int
    ) -> Float {
        let data = abl[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
        return data[interleaved ? frame * inChannels + channel : frame]
    }

    // MARK: Writer

    func startWriting() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Call only after the audio source has stopped delivering. Flushes and closes the file.
    func finish() {
        timer?.cancel()
        timer = nil
        queue.sync {
            drain()
            file = nil
        }
    }

    private func drain() {
        while true {
            let t = tail.load(ordering: .relaxed)
            let available = head.load(ordering: .acquiring) - t
            let frames = min(available / channels, scratchFrames)
            if frames == 0 { return }

            let out = scratch.floatChannelData![0]
            for i in 0..<(frames * channels) { out[i] = ring[(t + i) % capacity] }
            scratch.frameLength = AVAudioFrameCount(frames)
            do {
                try file?.write(from: scratch)
            } catch {
                failure.withLock { $0 = error.localizedDescription }
            }
            tail.store(t + frames * channels, ordering: .releasing)
            _ = framesWritten.add(frames, ordering: .relaxed)
        }
    }

    // MARK: Status (any thread)

    /// Peak since the previous call.
    func takePeak() -> Float { Float(bitPattern: peakBits.exchange(0, ordering: .relaxed)) }
    var frames: Int { framesWritten.load(ordering: .relaxed) }
    var dropped: Int { droppedFrames.load(ordering: .relaxed) }
    var firstHostTime: UInt64? { let v = firstHost.load(ordering: .relaxed); return v == 0 ? nil : v }
    var errorText: String? { failure.withLock { $0 } }
    var bytesWritten: Int { frames * channels * MemoryLayout<Float>.size }
}
