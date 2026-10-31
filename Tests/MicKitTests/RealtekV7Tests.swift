import MicKit
import XCTest

final class RealtekV7Tests: XCTestCase {
    func prefix(_ r: [UInt8]) -> [UInt8] { Array(r.prefix(3)) }

    func testReportShape() {
        let r = RealtekV7.setMuted(true)
        XCTAssertEqual(r.count, 64)
        XCTAssertEqual(prefix(r), [0x77, 0x06, 0x01])
        XCTAssertTrue(r.dropFirst(3).allSatisfy { $0 == 0 })
    }

    func testSetCommands() {
        XCTAssertEqual(prefix(RealtekV7.setMuted(false)), [0x77, 0x06, 0x00])
        XCTAssertEqual(prefix(RealtekV7.setHighPassFilter(true)), [0x77, 0x07, 0x01])
        XCTAssertEqual(prefix(RealtekV7.setInputLevel(42)), [0x77, 0x08, 42])
        XCTAssertEqual(prefix(RealtekV7.setOutputLevel(7)), [0x77, 0x09, 7])
        XCTAssertEqual(prefix(RealtekV7.setMonitoringBalance(3)), [0x77, 0x0A, 3])
    }

    // set_audio_input_polar_pattern: UI enum Cardioid(1)->1, Stereo(2)->3, Bidirectional(3)->0, Omni(4)->2
    func testPolarPatternWireValues() {
        XCTAssertEqual(prefix(RealtekV7.setPolarPattern(.cardioid)), [0x77, 0x05, 1])
        XCTAssertEqual(prefix(RealtekV7.setPolarPattern(.stereo)), [0x77, 0x05, 3])
        XCTAssertEqual(prefix(RealtekV7.setPolarPattern(.bidirectional)), [0x77, 0x05, 0])
        XCTAssertEqual(prefix(RealtekV7.setPolarPattern(.omnidirectional)), [0x77, 0x05, 2])
    }

    func testGetCommands() {
        XCTAssertEqual(prefix(RealtekV7.getReport(.polarPattern)), [0x77, 0x85, 0])
        XCTAssertEqual(prefix(RealtekV7.getReport(.inputMute)), [0x77, 0x86, 0])
        XCTAssertEqual(prefix(RealtekV7.getReport(.globalFilters)), [0x77, 0x87, 0])
        XCTAssertEqual(prefix(RealtekV7.getReport(.inputLevel)), [0x77, 0x88, 0])
        XCTAssertEqual(prefix(RealtekV7.getReport(.outputLevel)), [0x77, 0x89, 0])
        XCTAssertEqual(prefix(RealtekV7.getReport(.monitoringBalanceLevel)), [0x77, 0x8A, 0])
        XCTAssertEqual(prefix(RealtekV7.getReport(.monitoringBalanceStatus)), [0x77, 0x8C, 0])
    }

    func testParseResponses() {
        func r(_ b: UInt8...) -> [UInt8] { b + [UInt8](repeating: 0, count: 64 - b.count) }
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x86, 1)), .muted(true))
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x86, 0)), .muted(false))
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x85, 2)), .polarPattern(.omnidirectional))
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x87, 1)), .highPassFilter(true))
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x88, 80)), .inputLevel(80))
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x8A, 5)), .monitoringBalance(5))
        XCTAssertNil(RealtekV7.parse(r(0x11, 0x86, 1)))   // GET responses need the 0x77 header
        XCTAssertNil(RealtekV7.parse(r(0x77, 0x89, 1)))   // 0x89 replies carry no state
    }

    func testParseNotifications() {
        func r(_ b: UInt8...) -> [UInt8] { b + [UInt8](repeating: 0, count: 64 - b.count) }
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x06, 1)), .muted(true))
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x05, 3)), .polarPattern(.stereo))
        XCTAssertEqual(RealtekV7.parse(r(0x77, 0x0A, 0)), .monitoringBalance(0))
    }

    func testCatalog() {
        XCTAssertEqual(DeviceCatalog.model(forPID: 0x0FBF)?.name, "HyperX SoloCast 2")
        XCTAssertEqual(DeviceCatalog.model(forPID: 0x0FB4)?.name, "HyperX QuadCast 2 S")
        XCTAssertTrue(DeviceCatalog.model(forPID: 0x0D84)!.features.contains(.polarPattern))
        XCTAssertFalse(DeviceCatalog.model(forPID: 0x09C0)!.features.contains(.polarPattern))
    }

    func testLegacyMicsAreOSAudioOnly() {
        XCTAssertEqual(DeviceCatalog.model(forPID: 0x0491)?.name, "HyperX QuadCast")
        XCTAssertEqual(DeviceCatalog.model(forPID: 0x0F8B)?.name, "HyperX QuadCast S")
        XCTAssertEqual(DeviceCatalog.model(forPID: 0x0A92)?.name, "HyperX SoloCast")
        for pid: UInt16 in [0x0491, 0x0F8B, 0x0A92] {
            let m = DeviceCatalog.model(forPID: pid)!
            XCTAssertEqual(m.control, .osAudioOnly)
            XCTAssertTrue(m.features.isDisjoint(with: .hid))
        }
    }
}
