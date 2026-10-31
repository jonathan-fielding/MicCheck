// Supported mics: USB product IDs, control interface, and the features each one has.
//
// QuadCast, QuadCast S and SoloCast have no vendor HID control commands; they get
// the OS-level controls (gain, mute, headphone volume) that every mic has.

import Foundation

public struct MicFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Gain via the OS audio input device.
    public static let gain = MicFeatures(rawValue: 1 << 0)
    /// Mute via the OS audio input device (+ HID 0x06 on Realtek V7 mics to keep the LED in sync).
    public static let mute = MicFeatures(rawValue: 1 << 1)
    /// Headphone volume via the OS audio output device.
    public static let headphoneVolume = MicFeatures(rawValue: 1 << 2)
    /// HID 0x05.
    public static let polarPattern = MicFeatures(rawValue: 1 << 3)
    /// HID 0x0A, mic monitoring / playback mix.
    public static let monitoringMix = MicFeatures(rawValue: 1 << 4)
    /// HID 0x07, low-cut (high-pass) filter.
    public static let lowCutFilter = MicFeatures(rawValue: 1 << 5)
    /// QuadCast S top/bottom RGB (see docs/quadcast-s-lighting-protocol.md).
    public static let rgbLighting = MicFeatures(rawValue: 1 << 6)

    public static let osAudio: MicFeatures = [.gain, .mute, .headphoneVolume]
    public static let hid: MicFeatures = [.polarPattern, .monitoringMix, .lowCutFilter]
}

public enum ControlInterface: Sendable, Hashable {
    /// Vendor HID interface (usage page 0xFF90) speaking RealtekV7Protocol.
    case realtekV7
    /// No vendor HID control; OS audio only.
    case osAudioOnly
}

public struct MicModel: Sendable, Hashable, Identifiable {
    public let name: String
    public let control: ControlInterface
    /// USB PIDs that expose the vendor control interface (usage page 0xFF90).
    public let controlPIDs: Set<UInt16>
    /// PIDs used to find the OS audio device (VID 0x03F0).
    public let audioPIDs: Set<UInt16>
    /// Fallback match against the CoreAudio device name (e.g. Kingston-era units with VID 0x0951).
    public let nameKeyword: String
    public let features: MicFeatures
    public var id: String { name }
}

public enum DeviceCatalog {
    public static let vendorID: UInt16 = 0x03F0          // HP Inc. (HyperX)
    public static let controlUsagePage: UInt16 = 0xFF90  // vendor-defined control page

    public static let models: [MicModel] = [
        MicModel(name: "HyperX QuadCast 2 S", control: .realtekV7, controlPIDs: [0x0D84, 0x0FB4], audioPIDs: [0x0D84],
                 nameKeyword: "QuadCast 2 S", features: [.gain, .mute, .headphoneVolume, .polarPattern, .monitoringMix]),
        MicModel(name: "HyperX SoloCast 2 Pro", control: .realtekV7, controlPIDs: [0x02C8], audioPIDs: [0x02C8],
                 nameKeyword: "SoloCast 2 Pro", features: [.gain, .mute, .headphoneVolume, .lowCutFilter]),
        MicModel(name: "HyperX SoloCast 2", control: .realtekV7, controlPIDs: [0x0FBF], audioPIDs: [0x0FBF],
                 nameKeyword: "SoloCast 2", features: [.gain, .mute, .lowCutFilter]),
        MicModel(name: "HyperX FlipCast", control: .realtekV7, controlPIDs: [0x09C0], audioPIDs: [0x09C0],
                 nameKeyword: "FlipCast", features: [.gain, .mute, .headphoneVolume, .lowCutFilter]),
        // Name keywords run most-specific first, so "QuadCast S" is tried before "QuadCast".
        MicModel(name: "HyperX QuadCast S", control: .osAudioOnly, controlPIDs: [],
                 audioPIDs: [0x058C, 0x068C, 0x0D8B, 0x0E8B, 0x0F8B, 0x018C, 0x028C, 0x038C, 0x048C, 0x078C, 0x0294, 0x0394],
                 nameKeyword: "QuadCast S", features: MicFeatures.osAudio.union(.rgbLighting)),
        MicModel(name: "HyperX QuadCast", control: .osAudioOnly, controlPIDs: [], audioPIDs: [0x0491],
                 nameKeyword: "QuadCast", features: .osAudio),
        MicModel(name: "HyperX SoloCast", control: .osAudioOnly, controlPIDs: [],
                 audioPIDs: [0x078B, 0x098B, 0x0A8B, 0x0B8B, 0x088B, 0x0C8B, 0x0592, 0x0692, 0x0792, 0x0892, 0x0992, 0x0A92],
                 nameKeyword: "SoloCast", features: .osAudio),
    ]

    public static func model(forPID pid: UInt16) -> MicModel? {
        models.first { $0.controlPIDs.contains(pid) || $0.audioPIDs.contains(pid) }
    }

    /// Best catalog match for a CoreAudio device: VID:PID in the UID first, then the name.
    public static func model(for audio: AudioDevice) -> MicModel? {
        if let pid = audio.usbProductID(vendorID: vendorID), let m = model(forPID: pid) { return m }
        let name = audio.name.lowercased()
        return models.first { m in
            let k = m.nameKeyword.lowercased()
            // "QuadCast 2" must not be taken for a "QuadCast".
            return name.contains(k) && (k.contains(" 2") || !name.contains(k + " 2"))
        }
    }

    /// Mic monitoring mix: raw 0…6, shown relative to the centre value 3.
    public static let monitoringMixCenter: UInt8 = 3
    public static let monitoringMixRange: ClosedRange<Int> = 0...6
}
