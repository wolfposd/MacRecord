import CoreAudio

struct InputDevice: Identifiable, Hashable {
    let id: String               // device UID
    let name: String
    let deviceID: AudioObjectID
    let channels: Int
    let sampleRate: Double
}

enum InputDeviceCatalog {
    static func snapshot() -> [InputDevice] {
        let devices = (try? AudioObjectID.systemObject.getArray(
            kAudioHardwarePropertyDevices, as: AudioObjectID.self)) ?? []
        return devices.compactMap { device in
            let channels = device.inputChannelCount()
            guard channels > 0, let uid = device.getString(kAudioDevicePropertyDeviceUID) else { return nil }
            let rate = (try? device.get(kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 48_000
            return InputDevice(
                id: uid,
                name: device.getString(kAudioObjectPropertyName) ?? uid,
                deviceID: device,
                channels: channels,
                sampleRate: rate)
        }
    }

    static func defaultDeviceUID() -> String? {
        guard let device = try? AudioObjectID.systemObject.get(
            kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self) else { return nil }
        return device.getString(kAudioDevicePropertyDeviceUID)
    }
}
