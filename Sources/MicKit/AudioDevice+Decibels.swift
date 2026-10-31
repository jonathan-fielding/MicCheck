import CoreAudio

extension AudioDevice {
    /// Elements with a dB volume control: the main element, or else each channel.
    private func decibelElements(_ scope: AudioObjectPropertyScope) -> [AudioObjectPropertyElement] {
        func has(_ e: AudioObjectPropertyElement) -> Bool {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels, mScope: scope, mElement: e)
            return AudioObjectHasProperty(id, &addr)
        }
        if has(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...8).map(AudioObjectPropertyElement.init).filter(has)
    }

    public func canAdjustDecibels(_ scope: AudioObjectPropertyScope) -> Bool { !decibelElements(scope).isEmpty }

    /// Changes the hardware volume by `delta` dB, within the device's range. Returns the new level.
    @discardableResult
    public func adjustVolume(byDecibels delta: Double, _ scope: AudioObjectPropertyScope) -> Double? {
        var result: Double?
        for e in decibelElements(scope) {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels, mScope: scope, mElement: e)
            var db: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &db) == noErr else { continue }
            var rangeAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels, mScope: scope, mElement: e)
            var range = AudioValueRange(mMinimum: -96, mMaximum: 0)
            var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
            _ = AudioObjectGetPropertyData(id, &rangeAddr, 0, nil, &rangeSize, &range)
            var next = Float32(min(max(Double(db) + delta, range.mMinimum), range.mMaximum))
            if AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &next) == noErr {
                result = Double(next)
            }
        }
        return result
    }
}
