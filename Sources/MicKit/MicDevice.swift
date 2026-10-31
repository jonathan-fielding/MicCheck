import CoreAudio
import Foundation

/// One microphone as the UI sees it: an optional HID control interface
/// (Realtek V7 mics) plus the matching CoreAudio device.
public struct MicDevice: Identifiable {
    public let model: MicModel?
    public let hid: HIDMic?
    public let audio: AudioDevice?
    /// The model's features, limited to what this device actually exposes.
    /// Worked out once: the UI reads it on every redraw, and each check is a Core Audio query.
    public let features: MicFeatures

    init(model: MicModel?, hid: HIDMic?, audio: AudioDevice?) {
        self.model = model
        self.hid = hid
        self.audio = audio
        features = Self.features(model: model, hid: hid, audio: audio)
    }

    public var id: String {
        if let hid { return "hid:\(hid.productID):\(hid.serial ?? "")" }
        return "audio:\(audio?.uid ?? "")"
    }

    public var name: String { model?.name ?? hid?.displayName ?? audio?.name ?? "Microphone" }

    private static func features(model: MicModel?, hid: HIDMic?, audio: AudioDevice?) -> MicFeatures {
        var f = model?.features ?? (hid != nil ? MicFeatures.hid : [])
        if hid == nil { f.subtract(.hid) }
        if let a = audio {
            if !a.hasVolume(kAudioDevicePropertyScopeInput) { f.remove(.gain) }
            if !a.hasMute(kAudioDevicePropertyScopeInput) { f.remove(.mute) }
            if !(a.hasStreams(kAudioDevicePropertyScopeOutput) && a.hasVolume(kAudioDevicePropertyScopeOutput)) { f.remove(.headphoneVolume) }
        } else {
            f.subtract(.osAudio)
        }
        return f
    }

    /// HID mics first, then HyperX mics that only have OS audio controls.
    public static func discover(hidMics: [HIDMic]) -> [MicDevice] {
        let devices = AudioDevice.all()
        var result: [MicDevice] = hidMics.map { mic in
            MicDevice(model: mic.model, hid: mic, audio: mic.model.flatMap { AudioDevice.find(for: $0, in: devices) })
        }
        let used = Set(result.compactMap { $0.audio?.id })
        for a in devices where !used.contains(a.id) && a.hasStreams(kAudioDevicePropertyScopeInput) {
            guard let m = DeviceCatalog.model(for: a), m.control == .osAudioOnly else { continue }
            result.append(MicDevice(model: m, hid: nil, audio: a))
        }
        return result
    }
}
