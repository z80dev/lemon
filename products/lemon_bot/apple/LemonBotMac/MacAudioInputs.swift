import AudioToolbox
import CoreAudio
import Foundation

struct MacAudioInput: Identifiable, Hashable {
    let id: String
    let deviceID: AudioDeviceID
    let name: String
}

enum MacAudioInputs {
    static func available() throws -> [MacAudioInput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        try require(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount))
        var devices = [AudioDeviceID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioDeviceID>.stride)
        guard byteCount > 0 else { return [] }
        try devices.withUnsafeMutableBytes { bytes in
            try require(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, bytes.baseAddress!))
        }
        return try devices.compactMap { device in
            guard try hasInput(device) else { return nil }
            return MacAudioInput(id: try string(device, selector: kAudioDevicePropertyDeviceUID), deviceID: device, name: try string(device, selector: kAudioObjectPropertyName))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func select(_ uid: String?, on unit: AudioUnit?) throws {
        guard let uid else { return }
        guard let unit else { throw AudioInputError.message("The microphone audio unit is unavailable.") }
        guard let input = try available().first(where: { $0.id == uid }) else {
            throw AudioInputError.message("The selected microphone is disconnected. Choose an available input or System default.")
        }
        var device = input.deviceID
        try require(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
    }

    private static func hasInput(_ device: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        try require(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &byteCount))
        return byteCount > 0
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var byteCount = UInt32(MemoryLayout<CFString>.size)
        try require(AudioObjectGetPropertyData(device, &address, 0, nil, &byteCount, &value))
        return value as String
    }

    private static func require(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioInputError.message("Microphone device operation failed (OSStatus \(status)).") }
    }
}

private enum AudioInputError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        guard case .message(let message) = self else { return nil }
        return message
    }
}
