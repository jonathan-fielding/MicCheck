// Control protocol of the HyperX Realtek-based microphones
// (QuadCast 2 S, SoloCast 2, SoloCast 2 Pro, FlipCast).
//
// Every report is a 64-byte HID *output* report whose first byte is the
// report ID 0x77:
//
//   [0x77, command, value, 0, 0, ... 0]      (SET)
//   [0x77, command | 0x80, 0, ... 0]         (GET)
//
// The device answers on the same interface with an input report of the same
// shape; byte 1 echoes the command (GET responses keep the 0x80 bit).

import Foundation

public enum RealtekV7 {
    public static let reportID: UInt8 = 0x77
    public static let reportLength = 64
    static let getFlag: UInt8 = 0x80

    public enum Command: UInt8, CaseIterable {
        /// Polar pattern (GET 0x85)
        case polarPattern = 0x05
        /// Input mute (GET 0x86); value 1 = muted
        case inputMute = 0x06
        /// Input filters (GET 0x87); value 1 = high-pass (low-cut) on
        case globalFilters = 0x07
        /// Input level (GET 0x88); raw byte
        case inputLevel = 0x08
        /// Headphone (direct monitoring) level (GET 0x89)
        case outputLevel = 0x09
        /// Mic vs. playback monitoring mix (GET 0x8A)
        case monitoringBalanceLevel = 0x0A
        /// Monitoring mix status (GET 0x8C only)
        case monitoringBalanceStatus = 0x0C
    }

    public static func setReport(_ command: Command, value: UInt8) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: reportLength)
        r[0] = reportID
        r[1] = command.rawValue
        r[2] = value
        return r
    }

    public static func getReport(_ command: Command) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: reportLength)
        r[0] = reportID
        r[1] = command.rawValue | getFlag
        return r
    }

    public static func setPolarPattern(_ p: PolarPattern) -> [UInt8] { setReport(.polarPattern, value: p.rawValue) }
    public static func setMuted(_ muted: Bool) -> [UInt8] { setReport(.inputMute, value: muted ? 1 : 0) }
    public static func setHighPassFilter(_ on: Bool) -> [UInt8] { setReport(.globalFilters, value: on ? 1 : 0) }
    public static func setInputLevel(_ level: UInt8) -> [UInt8] { setReport(.inputLevel, value: level) }
    public static func setOutputLevel(_ level: UInt8) -> [UInt8] { setReport(.outputLevel, value: level) }
    public static func setMonitoringBalance(_ level: UInt8) -> [UInt8] { setReport(.monitoringBalanceLevel, value: level) }

    /// Decodes a report read from the device. Returns nil for reports with no
    /// meaningful state (including the 0x89 reply).
    public static func parse(_ report: [UInt8]) -> MicEvent? {
        guard report.count >= 3 else { return nil }
        let cmd = report[1], value = report[2]
        // GET responses carry the 0x77 header and keep the 0x80 bit.
        if report[0] == reportID, cmd & getFlag != 0 {
            switch cmd & ~getFlag {
            case Command.polarPattern.rawValue: return PolarPattern(rawValue: value).map(MicEvent.polarPattern)
            case Command.inputMute.rawValue: return .muted(value == 1)
            case Command.globalFilters.rawValue: return .highPassFilter(value == 1)
            case Command.inputLevel.rawValue: return .inputLevel(value)
            case Command.monitoringBalanceLevel.rawValue: return .monitoringBalance(value)
            default: return nil
            }
        }
        // Device-initiated changes (knob / tap-to-mute) and SET acks are identified
        // by byte 1 alone.
        switch cmd {
        case Command.polarPattern.rawValue: return PolarPattern(rawValue: value).map(MicEvent.polarPattern)
        case Command.inputMute.rawValue: return .muted(value == 1)
        case Command.monitoringBalanceLevel.rawValue: return .monitoringBalance(value)
        default: return nil
        }
    }
}

/// Wire values of the polar pattern byte.
public enum PolarPattern: UInt8, CaseIterable, Identifiable, Sendable {
    case bidirectional = 0
    case cardioid = 1
    case omnidirectional = 2
    case stereo = 3

    public var id: UInt8 { rawValue }
    public var displayName: String {
        switch self {
        case .cardioid: "Cardioid"
        case .omnidirectional: "Omnidirectional"
        case .stereo: "Stereo"
        case .bidirectional: "Bidirectional"
        }
    }
    /// Display order in the pickup pattern picker.
    public static let uiOrder: [PolarPattern] = [.cardioid, .omnidirectional, .stereo, .bidirectional]
}

public enum MicEvent: Equatable, Sendable {
    case polarPattern(PolarPattern)
    case muted(Bool)
    case highPassFilter(Bool)
    case inputLevel(UInt8)
    case monitoringBalance(UInt8)
}
