import CoreAudio
import AudioToolbox
import Foundation

enum AudioError: LocalizedError {
    case status(OSStatus, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .status(let status, let what): "\(what) failed (OSStatus \(status))"
        case .message(let text): text
        }
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AudioError.status(status, what) }
}

extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size, trivially-copyable property.
    func get<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self
    ) throws -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, ptr), "Reading audio property")
        return ptr.pointee
    }

    func getArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self
    ) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "Reading audio property size")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var status: OSStatus = noErr
        let result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var actual = size
            status = AudioObjectGetPropertyData(self, &addr, 0, nil, &actual, buffer.baseAddress!)
            initialized = status == noErr ? Int(actual) / MemoryLayout<T>.stride : 0
        }
        try check(status, "Reading audio property array")
        return result
    }

    func getString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Total number of input channels across all input streams of a device.
    func inputChannelCount() -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
