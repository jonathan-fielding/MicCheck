import Foundation
import IOKit
import IOKit.hid

/// Enum for discovering the lighting transport.
public enum LightingTransportFinder {
    /// Reasons the last `find()` failed.
    public nonisolated(unsafe) static var lastErrors: [String] = []

    /// Attempts to find the lighting transport, trying HID first, then raw USB.
    public static func find() -> LightingTransport? {
        var errors: [String] = []

        if let transport = findHID(errors: &errors) {
            lastErrors = []
            return transport
        }

        if let transport = findRawUSB(errors: &errors) {
            lastErrors = []
            return transport
        }

        lastErrors = errors
        return nil
    }

    private static func findHID(errors: inout [String]) -> LightingTransport? {
        // Create matching dictionaries for each device ID
        var devices: [IOHIDDevice] = []

        for (vid, pid) in quadCastSDeviceIDs {
            let matchDict: [String: Any] = [
                kIOHIDVendorIDKey: Int(vid),
                kIOHIDProductIDKey: Int(pid),
            ]

            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
            defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

            if let managerDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                devices.append(contentsOf: managerDevices)
            }
        }

        for device in devices {
            // Check interface number is 0 (search up the registry chain)
            if let interfaceNum = getInterfaceNumber(device), interfaceNum == 0 {
                let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
                let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
                let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
                if result == kIOReturnSuccess {
                    return HIDLighting(device, description: String(format: "HID (%04x:%04x, interface 0)", vid, pid))
                }
                errors.append(String(format: "%04x:%04x HID open failed: 0x%08X", vid, pid, result))
            }
        }

        // No HID device is the normal case (see findRawUSB), so only open failures are reported.
        return nil
    }

    private static func findRawUSB(errors: inout [String]) -> LightingTransport? {
        // Raw USB discovery: iterate IOUSBHostInterface services
        let matching = IOServiceMatching("IOUSBHostInterface")
        guard let matching = matching else {
            errors.append("Could not create matching dictionary for IOUSBHostInterface")
            return nil
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator)
        guard result == kIOReturnSuccess else {
            errors.append("IOServiceGetMatchingServices failed")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var foundAny = false

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else {
                break
            }
            defer { IOObjectRelease(service) }

            // Read properties directly from the service (no recursive search)
            guard let idVendor = (IORegistryEntryCreateCFProperty(
                service,
                "idVendor" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? NSNumber),
                  let idProduct = (IORegistryEntryCreateCFProperty(
                service,
                "idProduct" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? NSNumber),
                  let bInterfaceNumber = (IORegistryEntryCreateCFProperty(
                service,
                "bInterfaceNumber" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? NSNumber) else {
                continue
            }

            let vid = UInt16(idVendor.uint16Value)
            let pid = UInt16(idProduct.uint16Value)
            let interfaceNum = bInterfaceNumber.intValue

            guard quadCastSDeviceIDs.contains(where: { $0.vid == vid && $0.pid == pid }),
                  interfaceNum == 0 else {
                continue
            }

            foundAny = true

            do {
                return try RawUSBLighting(service: service, vid: vid, pid: pid)
            } catch {
                errors.append(String(format: "%04x:%04x interface 0: ", vid, pid) + error.localizedDescription)
            }
        }

        if !foundAny {
            errors.append("No matching interface present")
        }
        return nil
    }

    /// `bInterfaceNumber` can sit on the HID service or on one of its registry ancestors.
    private static func getInterfaceNumber(_ device: IOHIDDevice) -> Int? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        return IORegistryEntrySearchCFProperty(service, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
                                               IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int
    }
}
