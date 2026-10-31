import Foundation

// MARK: - Device ID List

/// Device IDs from the HyperX QuadCast S RGB Lighting Protocol specification. The HP
/// audio device (0x0294) is deliberately absent: lighting goes to the lighting device only.
internal let quadCastSDeviceIDs: [(vid: UInt16, pid: UInt16)] = [
    (0x0951, 0x171F),  // Kingston QuadCast S
    (0x03F0, 0x0F8B),  // HP QuadCast S variant
    (0x03F0, 0x068C),  // HP QuadCast S variant
    (0x03F0, 0x028C),  // HP QuadCast S lighting device
    (0x03F0, 0x048C),  // HP QuadCast S variant
    (0x03F0, 0x0D8B),  // HP QuadCast S variant
]

// MARK: - Packet Builders

/// Builds a colour packet for direct colour update (no save).
/// Offset 0: 0x81, then top LED RGB, then 0x81, then bottom LED RGB, rest 0x00.
internal func quadCastSBuildColorPacket(_ top: LEDColor, _ bottom: LEDColor) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: 64)
    packet[0] = 0x81
    packet[1] = top.r
    packet[2] = top.g
    packet[3] = top.b
    packet[4] = 0x81
    packet[5] = bottom.r
    packet[6] = bottom.g
    packet[7] = bottom.b
    return packet
}

/// Builds a register write packet for control commands.
/// Offset 0: 0x04 (register write marker), offset 1: register, offset 7: P1, offset 8: P2.
internal func quadCastSBuildRegisterWrite(_ register: UInt8, p1: UInt8, p2: UInt8) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: 64)
    packet[0] = 0x04
    packet[1] = register
    packet[7] = p1
    packet[8] = p2
    return packet
}

/// Builds an end-of-transfer packet to mark the end of a multi-packet sequence.
/// Offset 0: 0x08, offset 59: 0x28, offset 60: frame count, offset 61: 0x00,
/// offset 62: 0xAA, offset 63: 0x55.
internal func quadCastSBuildEndOfTransfer(frames: UInt8) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: 64)
    packet[0] = 0x08
    packet[59] = 0x28
    packet[60] = frames
    packet[61] = 0x00
    packet[62] = 0xAA
    packet[63] = 0x55
    return packet
}

// MARK: - Sequence Builders

/// Builds the direct-colour update sequence: colour packet + apply register (0xF2, P1=0, P2=1).
/// Returns an array of (packet, delay in seconds) tuples.
internal func quadCastSBuildDirectColorUpdateSequence(_ top: LEDColor, _ bottom: LEDColor)
    -> [(packet: [UInt8], delay: TimeInterval)] {
    [
        (quadCastSBuildColorPacket(top, bottom), 0.015),
        (quadCastSBuildRegisterWrite(0xF2, p1: 0, p2: 1), 0.015),
    ]
}

/// Builds the save-to-device sequence: 8 packets with 15 ms delays between each.
/// Returns an array of (packet, delay in seconds) tuples.
internal func quadCastSBuildSaveSequence(_ top: LEDColor, _ bottom: LEDColor)
    -> [(packet: [UInt8], delay: TimeInterval)] {
    [
        (quadCastSBuildRegisterWrite(0x53, p1: 1, p2: 0), 0.015),  // Begin save
        (quadCastSBuildColorPacket(top, bottom), 0.015),           // Colour frame
        (quadCastSBuildRegisterWrite(0x02, p1: 0, p2: 0), 0.015),  // Commit
        (quadCastSBuildRegisterWrite(0x23, p1: 1, p2: 0), 0.015),  // End save
        (quadCastSBuildEndOfTransfer(frames: 1), 0.015),            // End-of-transfer
        (quadCastSBuildRegisterWrite(0x02, p1: 0, p2: 0), 0.015),  // Commit
        (quadCastSBuildColorPacket(top, bottom), 0.015),            // Colour frame
        (quadCastSBuildRegisterWrite(0xF2, p1: 0, p2: 1), 0.015),  // Apply
    ]
}
