import AVFoundation

enum AudioConverter {
    struct Cancelled: Error {}

    /// Encodes `source` (e.g. a CAF) to AAC in an `.m4a` next to it and returns the new URL.
    /// The source is never touched. Writes to a hidden temp file first, verifies it, then renames it
    /// into place, so a crash or cancel never leaves a half-written `.m4a` that looks real.
    /// Blocking: call off the main thread. `progress` gets 0...1 for this file.
    static func convertToAAC(
        source: URL, progress: (Double) -> Void, isCancelled: () -> Bool
    ) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let name = source.deletingPathExtension().lastPathComponent
        let directory = source.deletingLastPathComponent()
        let destination = directory.appendingPathComponent("\(name).m4a")
        let temp = directory.appendingPathComponent(".converting-\(name).m4a")   // dot-prefix: ignored by listings
        defer { try? FileManager.default.removeItem(at: temp) }                  // no-op after a successful move

        // ~48 kbps per channel; if the encoder refuses that for an unusual sample rate, use its quality preset.
        do {
            try encode(input, to: temp, bitRatePerChannel: 48_000, progress: progress, isCancelled: isCancelled)
        } catch is Cancelled {
            throw Cancelled()
        } catch {
            input.framePosition = 0
            try? FileManager.default.removeItem(at: temp)
            try encode(input, to: temp, bitRatePerChannel: nil, progress: progress, isCancelled: isCancelled)
        }

        // Verify before anything is replaced or deleted.
        let output = try AVAudioFile(forReading: temp)
        let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, abs(output.length - input.length) <= 8192 else {
            throw AudioError.message("The converted file did not match the original.")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    private static func encode(
        _ input: AVAudioFile, to url: URL, bitRatePerChannel: Int?,
        progress: (Double) -> Void, isCancelled: () -> Bool
    ) throws {
        let format = input.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        if let bitRatePerChannel {
            settings[AVEncoderBitRatePerChannelKey] = bitRatePerChannel
        } else {
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.medium.rawValue
        }

        let output = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)!
        let total = max(input.length, 1)
        while input.framePosition < input.length {
            if isCancelled() { throw Cancelled() }
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            progress(Double(input.framePosition) / Double(total))
        }
        output.close()      // finalizes the m4a
    }
}
