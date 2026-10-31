@testable import MicKit
import XCTest

final class QuadCastSLightingTests: XCTestCase {
    // MARK: - LEDColor Tests

    func testLEDColorInit() {
        let color = LEDColor(r: 255, g: 16, b: 32)
        XCTAssertEqual(color.r, 255)
        XCTAssertEqual(color.g, 16)
        XCTAssertEqual(color.b, 32)
    }

    func testLEDColorOff() {
        let color = LEDColor.off
        XCTAssertEqual(color.r, 0)
        XCTAssertEqual(color.g, 0)
        XCTAssertEqual(color.b, 0)
    }

    func testLEDColorHexParsing() {
        let red = LEDColor(hex: "FF0000")
        XCTAssertNotNil(red)
        XCTAssertEqual(red?.r, 255)
        XCTAssertEqual(red?.g, 0)
        XCTAssertEqual(red?.b, 0)

        let green = LEDColor(hex: "#00FF00")
        XCTAssertNotNil(green)
        XCTAssertEqual(green?.r, 0)
        XCTAssertEqual(green?.g, 255)
        XCTAssertEqual(green?.b, 0)

        let blue = LEDColor(hex: "0000ff")
        XCTAssertNotNil(blue)
        XCTAssertEqual(blue?.r, 0)
        XCTAssertEqual(blue?.g, 0)
        XCTAssertEqual(blue?.b, 255)
    }

    func testLEDColorHexParsingInvalid() {
        XCTAssertNil(LEDColor(hex: "GGGGGG"))
        XCTAssertNil(LEDColor(hex: "FF00"))
        XCTAssertNil(LEDColor(hex: "#FF000000"))
        XCTAssertNil(LEDColor(hex: ""))
    }

    func testLEDColorHexFormatting() {
        let red = LEDColor(r: 255, g: 16, b: 32)
        XCTAssertEqual(red.hex, "ff1020")

        let blue = LEDColor(r: 1, g: 2, b: 254)
        XCTAssertEqual(blue.hex, "0102fe")

        let black = LEDColor.off
        XCTAssertEqual(black.hex, "000000")
    }

    func testLEDColorHexRoundTrip() {
        let colors = [
            LEDColor(r: 255, g: 16, b: 32),
            LEDColor(r: 1, g: 2, b: 254),
            LEDColor(r: 128, g: 64, b: 32),
            LEDColor.off,
        ]

        for color in colors {
            let hex = color.hex
            let roundTrip = LEDColor(hex: hex)
            XCTAssertEqual(roundTrip, color, "Hex round-trip failed for \(hex)")
        }
    }

    func testBrightnessScaling() {
        // Test exact value: 200 * 0.5 = 100
        let color = LEDColor(r: 200, g: 100, b: 50)
        let scaled = color.scaled(0.5)
        XCTAssertEqual(scaled.r, 100)
        XCTAssertEqual(scaled.g, 50)
        XCTAssertEqual(scaled.b, 25)

        // Test rounding: 100 * 0.5 = 50, which is exact
        let color2 = LEDColor(r: 100, g: 0, b: 0)
        let scaled2 = color2.scaled(0.5)
        XCTAssertEqual(scaled2.r, 50)

        // Test rounding up: 101 * 0.5 = 50.5 -> rounds to 51 (0.5 rounds away from zero)
        let color3 = LEDColor(r: 101, g: 0, b: 0)
        let scaled3 = color3.scaled(0.5)
        XCTAssertEqual(scaled3.r, 51)

        // Test 0.5 rounding: 255 * 0.5 = 127.5 -> rounds to 128
        let color4 = LEDColor(r: 255, g: 0, b: 0)
        let scaled4 = color4.scaled(0.5)
        XCTAssertEqual(scaled4.r, 128)

        // Test clamping: brightness > 1 is clamped, result is clamped to 255
        let color5 = LEDColor(r: 255, g: 255, b: 255)
        let scaled5 = color5.scaled(1.5)
        XCTAssertEqual(scaled5.r, 255)
        XCTAssertEqual(scaled5.g, 255)
        XCTAssertEqual(scaled5.b, 255)

        // Test zero brightness
        let color6 = LEDColor(r: 255, g: 128, b: 64)
        let scaled6 = color6.scaled(0.0)
        XCTAssertEqual(scaled6.r, 0)
        XCTAssertEqual(scaled6.g, 0)
        XCTAssertEqual(scaled6.b, 0)

        // Test full brightness
        let color7 = LEDColor(r: 255, g: 128, b: 64)
        let scaled7 = color7.scaled(1.0)
        XCTAssertEqual(scaled7.r, 255)
        XCTAssertEqual(scaled7.g, 128)
        XCTAssertEqual(scaled7.b, 64)

        // Test negative brightness is clamped to 0
        let color8 = LEDColor(r: 255, g: 128, b: 64)
        let scaled8 = color8.scaled(-0.5)
        XCTAssertEqual(scaled8.r, 0)
        XCTAssertEqual(scaled8.g, 0)
        XCTAssertEqual(scaled8.b, 0)
    }

    func testLEDColorEquatable() {
        let c1 = LEDColor(r: 255, g: 16, b: 32)
        let c2 = LEDColor(r: 255, g: 16, b: 32)
        let c3 = LEDColor(r: 255, g: 16, b: 31)

        XCTAssertEqual(c1, c2)
        XCTAssertNotEqual(c1, c3)
    }

    func testLEDColorHashable() {
        let c1 = LEDColor(r: 255, g: 16, b: 32)
        let c2 = LEDColor(r: 255, g: 16, b: 32)

        var set = Set<LEDColor>()
        set.insert(c1)
        XCTAssertTrue(set.contains(c2))
    }

    // MARK: - Packet Building Tests

    func testColorPacket() {
        let packet = quadCastSBuildColorPacket(
            LEDColor(r: 0xFF, g: 0x10, b: 0x20),
            LEDColor(r: 0x01, g: 0x02, b: 0xFE)
        )

        let expected: [UInt8] = [
            0x81, 0xFF, 0x10, 0x20, 0x81, 0x01, 0x02, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(packet, expected)
    }

    func testApplyPacket() {
        let packet = quadCastSBuildRegisterWrite(0xF2, p1: 0, p2: 1)

        let expected: [UInt8] = [
            0x04, 0xF2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(packet, expected)
    }

    func testEndOfTransferPacket() {
        let packet = quadCastSBuildEndOfTransfer(frames: 1)

        let expected: [UInt8] = [
            0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x01, 0x00, 0xAA, 0x55,
        ]
        XCTAssertEqual(packet, expected)
    }

    func testBeginSavePacket() {
        let packet = quadCastSBuildRegisterWrite(0x53, p1: 1, p2: 0)

        let expected: [UInt8] = [
            0x04, 0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(packet, expected)
    }

    func testEndSavePacket() {
        let packet = quadCastSBuildRegisterWrite(0x23, p1: 1, p2: 0)

        let expected: [UInt8] = [
            0x04, 0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(packet, expected)
    }

    func testCommitPacket() {
        let packet = quadCastSBuildRegisterWrite(0x02, p1: 0, p2: 0)

        let expected: [UInt8] = [
            0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(packet, expected)
    }

    func testSaveSequence() {
        let top = LEDColor(r: 0xFF, g: 0x10, b: 0x20)
        let bottom = LEDColor(r: 0x01, g: 0x02, b: 0xFE)
        let sequence = quadCastSBuildSaveSequence(top, bottom)

        // Should have 8 packets
        XCTAssertEqual(sequence.count, 8)

        // Each packet should be 64 bytes and followed by 15ms delay
        for (packet, delay) in sequence {
            XCTAssertEqual(packet.count, 64)
            XCTAssertEqual(delay, 0.015)
        }

        // Verify the sequence structure:
        // 1. Begin save (0x53, P1=1)
        XCTAssertEqual(sequence[0].packet[0], 0x04)
        XCTAssertEqual(sequence[0].packet[1], 0x53)
        XCTAssertEqual(sequence[0].packet[7], 0x01)

        // 2. Colour frame
        XCTAssertEqual(sequence[1].packet[0], 0x81)

        // 3. Commit (0x02)
        XCTAssertEqual(sequence[2].packet[0], 0x04)
        XCTAssertEqual(sequence[2].packet[1], 0x02)

        // 4. End save (0x23, P1=1)
        XCTAssertEqual(sequence[3].packet[0], 0x04)
        XCTAssertEqual(sequence[3].packet[1], 0x23)

        // 5. End-of-transfer
        XCTAssertEqual(sequence[4].packet[0], 0x08)

        // 6. Commit (0x02)
        XCTAssertEqual(sequence[5].packet[0], 0x04)
        XCTAssertEqual(sequence[5].packet[1], 0x02)

        // 7. Colour frame
        XCTAssertEqual(sequence[6].packet[0], 0x81)

        // 8. Apply (0xF2, P1=0, P2=1)
        XCTAssertEqual(sequence[7].packet[0], 0x04)
        XCTAssertEqual(sequence[7].packet[1], 0xF2)
        XCTAssertEqual(sequence[7].packet[8], 0x01)
    }

    func testDirectColorUpdateSequence() {
        let top = LEDColor(r: 0xFF, g: 0x10, b: 0x20)
        let bottom = LEDColor(r: 0x01, g: 0x02, b: 0xFE)
        let sequence = quadCastSBuildDirectColorUpdateSequence(top, bottom)

        // Should have 2 packets
        XCTAssertEqual(sequence.count, 2)

        // 1. Colour packet
        XCTAssertEqual(sequence[0].packet[0], 0x81)
        XCTAssertEqual(sequence[0].delay, 0.015)

        // 2. Apply register (0xF2)
        XCTAssertEqual(sequence[1].packet[0], 0x04)
        XCTAssertEqual(sequence[1].packet[1], 0xF2)
        XCTAssertEqual(sequence[1].delay, 0.015)
    }

    func testDeviceIDList() {
        // Verify all device IDs are present
        XCTAssertEqual(quadCastSDeviceIDs.count, 6)

        // Check specific IDs are in the list
        XCTAssertTrue(quadCastSDeviceIDs.contains { $0.vid == 0x0951 && $0.pid == 0x171F })
        XCTAssertTrue(quadCastSDeviceIDs.contains { $0.vid == 0x03F0 && $0.pid == 0x028C })
        // The audio device's interface 0 is Audio Control, never the lighting interface.
        XCTAssertFalse(quadCastSDeviceIDs.contains { $0.vid == 0x03F0 && $0.pid == 0x0294 })
    }

    // MARK: - Controller

    /// Colour packets the controller sent, in order.
    private func colorPackets(_ t: MockTransport) -> [[UInt8]] { t.sentPackets.filter { $0[0] == 0x81 } }

    /// Waits until everything queued on the controller has run, using a save as a barrier.
    /// Returns how many packets were sent before the save's own packets.
    private func drain(_ c: QuadCastSLightController, _ t: MockTransport) -> Int {
        let done = expectation(description: "drained")
        c.save(top: .off, bottom: .off) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        return t.sentPackets.count - quadCastSBuildSaveSequence(.off, .off).count
    }

    func testShowBurstDoesNotQueueAnUpdatePerCall() {
        let t = MockTransport()
        let c = QuadCastSLightController(transport: t)
        let last = LEDColor(r: 1, g: 2, b: 3)
        for i in 0..<40 { c.show(top: LEDColor(r: UInt8(i + 10), g: 0, b: 0), bottom: .off) }
        c.show(top: last, bottom: last)
        Thread.sleep(forTimeInterval: 0.12)   // two or three keep-alive ticks
        c.stop()
        let streamed = drain(c, t)
        // One update is two packets. Sending per call would be 41 updates before the first tick.
        XCTAssertLessThanOrEqual(streamed, 2 * 5)
        XCTAssertEqual(Array(colorPackets(t).dropLast(2).last?[1...3] ?? []), [1, 2, 3], "the keep-alive must send the latest colours")
    }

    func testFailedSendStopsKeepAlive() {
        let t = FailingTransport()
        let c = QuadCastSLightController(transport: t)
        let errors = ErrorLog()
        c.onError = { errors.append($0) }
        c.show(top: .off, bottom: .off)
        Thread.sleep(forTimeInterval: 0.15)
        c.stop()
        let done = expectation(description: "drained")
        c.save(top: .off, bottom: .off) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        // The first show fails; no keep-alive tick may retry a dead handle. The save fails once more.
        XCTAssertEqual(t.attempts, 2)
        XCTAssertEqual(errors.messages.first ?? nil, "boom")
    }
}

// MARK: - Mock Transport

final class FailingTransport: LightingTransport {
    var transportDescription: String { "Failing" }
    var attempts = 0

    func sendFeature(_ packet: [UInt8]) throws {
        attempts += 1
        throw LightingError.sendFailed("boom")
    }

    func close() {}
}

final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String?] = []
    var messages: [String?] { lock.withLock { _messages } }
    func append(_ m: String?) { lock.withLock { _messages.append(m) } }
}

final class MockTransport: LightingTransport {
    var transportDescription: String { "Mock" }
    var sentPackets: [[UInt8]] = []

    func sendFeature(_ packet: [UInt8]) throws {
        sentPackets.append(packet)
    }

    func close() {}
}
