import Foundation
import IOUSBHost
import IOKit

/// Sends lighting commands via raw USB class request (Option B in the spec).
final class RawUSBLighting: LightingTransport {
    private let interface: IOUSBHostInterface
    private let description: String
    private var closed = false

    init(service: io_service_t, vid: UInt16, pid: UInt16) throws {
        interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        description = String(format: "USB control transfer (%04x:%04x, interface 0)", vid, pid)
    }

    var transportDescription: String { description }

    func sendFeature(_ packet: [UInt8]) throws {
        guard packet.count == 64 else {
            throw LightingError.invalidPacketSize
        }

        let iface = interface

        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x21    // Host-to-device, class, interface
        req.bRequest = 0x09         // SET_REPORT
        req.wValue = 0x0300         // Report type feature (3 << 8), report ID 0
        req.wIndex = 0x0000         // Interface 0
        req.wLength = UInt16(64)    // Payload size

        let data = NSMutableData(bytes: packet, length: 64)
        var transferred = 0

        do {
            try iface.__send(req, data: data, bytesTransferred: &transferred, completionTimeout: 1.0)
        } catch {
            throw LightingError.sendFailed("USB control transfer failed: \(error.localizedDescription)")
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        interface.destroy()
    }

    deinit {
        close()
    }
}
