// Gain / mute / headphone volume through CoreAudio, on the audio device whose
// USB product ID matches the mic.

import CoreAudio
import Foundation

public struct AudioDevice: Hashable, Sendable {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
    public let modelUID: String

    public static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        // A device can go away between the two calls; `size` now holds what was actually returned.
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).map { id in
            AudioDevice(id: id,
                        name: stringProperty(id, kAudioObjectPropertyName) ?? "",
                        uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                        modelUID: stringProperty(id, kAudioDevicePropertyModelUID) ?? "")
        }
    }

    /// The input device for a catalog model: VID:PID in the UID first, then the name keyword.
    public static func find(for model: MicModel, in devices: [AudioDevice] = all()) -> AudioDevice? {
        let inputs = devices.filter { $0.hasStreams(kAudioDevicePropertyScopeInput) }
        if let d = inputs.first(where: { $0.usbProductID(vendorID: DeviceCatalog.vendorID).map(model.audioPIDs.contains) ?? false }) { return d }
        return inputs.first { DeviceCatalog.model(for: $0) == model }
    }

    /// Parses "…:VVVV:PPPP" from the ModelUID / UID that USB audio devices report.
    public func usbProductID(vendorID: UInt16) -> UInt16? {
        let vid = String(format: "%04X", vendorID)
        for s in [modelUID, uid] {
            let parts = s.uppercased().split(separator: ":")
            for (i, p) in parts.enumerated() where p == vid && i + 1 < parts.count {
                if let pid = UInt16(parts[i + 1].prefix(4), radix: 16) { return pid }
            }
        }
        return nil
    }

    public func hasVolume(_ scope: AudioObjectPropertyScope) -> Bool { !volumeElements(scope).isEmpty }

    public func hasMute(_ scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(id, &addr)
    }

    // MARK: change notifications

    /// Calls `handler` on the main queue when devices are added or removed.
    public static func observeDeviceList(_ handler: @escaping @Sendable () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in handler() }
    }

    /// Calls `handler` on the main queue when volume or mute changes in either scope,
    /// until the returned observation is cancelled or released.
    public func observeLevels(_ handler: @escaping @Sendable () -> Void) -> PropertyObservation {
        let observation = PropertyObservation(objectID: id)
        for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
            for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                for el in [kAudioObjectPropertyElementMain] + (1...2).map(AudioObjectPropertyElement.init) {
                    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
                    guard AudioObjectHasProperty(id, &addr) else { continue }
                    let b: AudioObjectPropertyListenerBlock = { _, _ in handler() }
                    if AudioObjectAddPropertyListenerBlock(id, &addr, .main, b) == noErr { observation.listeners.append((addr, b)) }
                }
            }
        }
        return observation
    }

    public func hasStreams(_ scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    // MARK: volume (0...1) and mute

    public func volume(_ scope: AudioObjectPropertyScope) -> Float? {
        for element in volumeElements(scope) {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    @discardableResult
    public func setVolume(_ value: Float, _ scope: AudioObjectPropertyScope) -> Bool {
        var ok = false
        for element in volumeElements(scope) {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            var v = Float32(min(max(value, 0), 1))
            ok = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr || ok
        }
        return ok
    }

    public func muted(_ scope: AudioObjectPropertyScope) -> Bool? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v != 0 : nil
    }

    @discardableResult
    public func setMuted(_ muted: Bool, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    /// Main element if it has a volume control, otherwise the per-channel ones.
    private func volumeElements(_ scope: AudioObjectPropertyScope) -> [AudioObjectPropertyElement] {
        func settable(_ e: AudioObjectPropertyElement) -> Bool {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: e)
            return AudioObjectHasProperty(id, &addr)
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...8).map(AudioObjectPropertyElement.init).filter(settable)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}

/// Property listeners registered on one audio object; removed on `cancel()` or release.
public final class PropertyObservation {
    let objectID: AudioObjectID
    var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(objectID: AudioObjectID) { self.objectID = objectID }
    deinit { cancel() }

    public func cancel() {
        for (address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(objectID, &addr, .main, block)
        }
        listeners = []
    }
}
