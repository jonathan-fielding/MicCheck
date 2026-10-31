// Small Core Audio helpers shared by the meter, the recorder and the live voice router.

import CoreAudio
import Foundation

public enum AudioHAL {
    /// Finds a device by UID, including hidden ones (which kAudioHardwarePropertyDevices leaves out).
    public static func device(uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &id)
        }
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    public static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }

    /// True while any process is doing IO on the device.
    public static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    /// Calls `handler` on the main queue when the device starts or stops running anywhere.
    public static func observeRunning(_ id: AudioObjectID, _ handler: @escaping @Sendable () -> Void) -> PropertyObservation {
        let observation = PropertyObservation(objectID: id)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let b: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(id, &addr, .main, b) == noErr { observation.listeners.append((addr, b)) }
        return observation
    }

    /// The IOProcs read and write every buffer as Float32; true when each stream in `scope` uses it.
    public static func streamsAreFloat32(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr else { return false }
        for stream in streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size) {
            var formatAddr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddr, 0, nil, &formatSize, &format) == noErr,
                  format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { return false }
        }
        return true
    }

    /// Averages every channel of every buffer into `out` (mono). Returns the frame count written.
    @inline(__always)
    public static func downmix(_ input: UnsafePointer<AudioBufferList>, into out: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frames = 0, totalChannels = 0
        for b in buffers where b.mData != nil && b.mNumberChannels > 0 {
            let ch = Int(b.mNumberChannels)
            frames = max(frames, min(Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch), capacity))
        }
        guard frames > 0 else { return 0 }
        out.update(repeating: 0, count: frames)
        for b in buffers {
            guard let data = b.mData, b.mNumberChannels > 0 else { continue }
            let ch = Int(b.mNumberChannels)
            let n = min(Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch), frames)
            let p = data.assumingMemoryBound(to: Float.self)
            for c in 0..<ch {
                for i in 0..<n { out[i] += p[i * ch + c] }
            }
            totalChannels += ch
        }
        if totalChannels > 1 {
            let k = 1 / Float(totalChannels)
            for i in 0..<frames { out[i] *= k }
        }
        return frames
    }
}
