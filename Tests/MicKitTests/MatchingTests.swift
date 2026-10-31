@testable import MicKit
import XCTest

final class MatchingTests: XCTestCase {
    func dev(_ name: String, model: String = "") -> AudioDevice { AudioDevice(id: 1, name: name, uid: "uid", modelUID: model) }

    func testPIDFromModelUID() {
        XCTAssertEqual(dev("x", model: "HyperX QuadCast S:03F0:0F8B").usbProductID(vendorID: 0x03F0), 0x0F8B)
        XCTAssertNil(dev("x", model: "Digital Mic").usbProductID(vendorID: 0x03F0))
    }

    func testPIDWinsOverName() {
        XCTAssertEqual(DeviceCatalog.model(for: dev("Mic", model: "Mic:03F0:0491"))?.name, "HyperX QuadCast")
    }

    func testNameFallback() {
        // e.g. Kingston-era units (VID 0x0951), whose PIDs aren't in the catalog
        XCTAssertEqual(DeviceCatalog.model(for: dev("HyperX QuadCast S", model: "HyperX QuadCast S:0951:171F"))?.name, "HyperX QuadCast S")
        XCTAssertEqual(DeviceCatalog.model(for: dev("HyperX QuadCast"))?.name, "HyperX QuadCast")
        XCTAssertEqual(DeviceCatalog.model(for: dev("HyperX SoloCast"))?.name, "HyperX SoloCast")
        XCTAssertEqual(DeviceCatalog.model(for: dev("HyperX SoloCast 2"))?.name, "HyperX SoloCast 2")
        XCTAssertEqual(DeviceCatalog.model(for: dev("HyperX QuadCast 2 S"))?.name, "HyperX QuadCast 2 S")
        XCTAssertNil(DeviceCatalog.model(for: dev("HyperX QuadCast 2")))   // not in the catalog; must not become "QuadCast"
        XCTAssertNil(DeviceCatalog.model(for: dev("MacBook Pro Microphone")))
    }
}
