import Foundation
import IOKit
import IOKit.usb

/// Sends lighting commands via a raw USB class request (Option B in the spec).
///
/// Uses the IOUSBLib plug-in rather than the IOUSBHost framework: the App Sandbox's
/// `com.apple.security.device.usb` entitlement only allows IOUSBLib's user clients
/// (`IOUSBInterfaceUserClientV3`), so IOUSBHost fails with "not permitted" when sandboxed.
final class RawUSBLighting: LightingTransport {
    private typealias Interface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface300>?>
    private let interface: Interface
    private let description: String
    private var closed = false

    // The IOUSBLib.h UUIDs are C macros that Swift can't import.
    private static let interfaceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4, 0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(
        nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let interfaceInterfaceID300 = CFUUIDGetConstantUUIDWithBytes(
        nil, 0xBC, 0xEA, 0xAD, 0xDC, 0x88, 0x4D, 0x4F, 0x27, 0x83, 0x40, 0x36, 0xD6, 0x9F, 0xAB, 0x90, 0xF6)

    init(service: io_service_t, vid: UInt16, pid: UInt16) throws {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(service, Self.interfaceUserClientTypeID, Self.plugInInterfaceID, &plugIn, &score)
        guard kr == kIOReturnSuccess, let plugIn, let plugInFns = plugIn.pointee?.pointee else {
            throw LightingError.sendFailed(String(format: "USB plug-in unavailable: 0x%08X", kr))
        }
        defer { _ = plugInFns.Release(plugIn) }

        var iface: Interface?
        let hr = withUnsafeMutablePointer(to: &iface) {
            $0.withMemoryRebound(to: LPVOID?.self, capacity: 1) {
                plugInFns.QueryInterface(plugIn, CFUUIDGetUUIDBytes(Self.interfaceInterfaceID300), $0)
            }
        }
        guard hr == 0, let iface, let fns = iface.pointee?.pointee else {
            throw LightingError.sendFailed("USB interface query failed: \(hr)")
        }
        let openResult = fns.USBInterfaceOpen(iface)
        guard openResult == kIOReturnSuccess else {
            _ = fns.Release(iface)
            throw LightingError.sendFailed(String(format: "USB interface open failed: 0x%08X", openResult))
        }
        interface = iface
        description = String(format: "USB control transfer (%04x:%04x, interface 0)", vid, pid)
    }

    var transportDescription: String { description }

    func sendFeature(_ packet: [UInt8]) throws {
        guard packet.count == 64 else {
            throw LightingError.invalidPacketSize
        }
        guard !closed, let fns = interface.pointee?.pointee else {
            throw LightingError.sendFailed("USB interface closed")
        }
        var data = packet
        let result = data.withUnsafeMutableBytes { buf in
            var req = IOUSBDevRequestTO(
                bmRequestType: 0x21,      // Host-to-device, class, interface
                bRequest: 0x09,           // SET_REPORT
                wValue: 0x0300,           // Report type feature (3 << 8), report ID 0
                wIndex: 0x0000,           // Interface 0
                wLength: 64,
                pData: buf.baseAddress,
                wLenDone: 0,
                noDataTimeout: 1000,      // ms
                completionTimeout: 1000)  // ms
            return fns.ControlRequestTO(interface, 0, &req)
        }
        guard result == kIOReturnSuccess else {
            throw LightingError.sendFailed(String(format: "USB control transfer failed: 0x%08X", result))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let fns = interface.pointee?.pointee {
            _ = fns.USBInterfaceClose(interface)
            _ = fns.Release(interface)
        }
    }

    deinit {
        close()
    }
}
