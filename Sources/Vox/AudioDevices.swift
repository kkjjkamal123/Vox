import CoreAudio
import Foundation

/// Which microphone to listen with. Opening a Bluetooth headset's mic switches it from music (A2DP) to
/// call mode (HFP): music turns mono and muffled, and the first second of speech is lost while the link
/// switches. So when the default input is Bluetooth, Vox listens with the Mac's built-in mic instead.
enum AudioDevices {
    static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transport(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's own microphone, if it has one.
    static func builtInInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    /// Ask the device to hand audio over in big chunks (for this process only). The default 512 frames means
    /// ~94 wakeups a second in Vox and in coreaudiod; Vox works in 100 ms pieces anyway, so the largest buffer
    /// the device allows (usually 4096 frames, 85 ms) cuts that eightfold at no cost in responsiveness.
    static func useLargeBuffers(_ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &range) == noErr else { return }
        var frames = UInt32(min(range.mMaximum, 4096))
        addr.mSelector = kAudioDevicePropertyBufferFrameSize
        let err = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        if err != noErr { NSLog("Vox: couldn't set the mic buffer size: \(err)") }
    }

    static func bufferFrames(_ id: AudioDeviceID) -> UInt32 {
        var f: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &f)
        return f
    }

    static func name(_ id: AudioDeviceID) -> String {
        var n: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &n) == noErr, let n else { return "device \(id)" }
        return n.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr ? t : 0
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}
