import Foundation
import IOKit
import IOKit.hid

/// Sends lighting commands via HID SetReport (Option A in the spec).
final class HIDLighting: LightingTransport {
    private let device: IOHIDDevice
    private let description: String

    init(_ device: IOHIDDevice, description: String = "HID") {
        self.device = device
        self.description = description
    }

    var transportDescription: String { description }

    func sendFeature(_ packet: [UInt8]) throws {
        guard packet.count == 64 else {
            throw LightingError.invalidPacketSize
        }
        var mutablePacket = packet
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0), &mutablePacket, mutablePacket.count)
        guard result == kIOReturnSuccess else {
            let hexCode = String(format: "0x%08X", result)
            throw LightingError.sendFailed("HID SetReport failed: \(hexCode)")
        }
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
