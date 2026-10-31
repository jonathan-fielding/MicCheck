// IOKit HID transport for the Realtek V7 control interface: 64-byte output
// reports out (report ID = byte 0), input reports back through a callback.

import Foundation
import IOKit
import IOKit.hid

public final class HIDMic: @unchecked Sendable {
    public let device: IOHIDDevice
    public let productID: UInt16
    public let model: MicModel?
    public let serial: String?
    public var onEvent: ((MicEvent) -> Void)?
    public var onRawReport: (([UInt8]) -> Void)?

    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init(device: IOHIDDevice) {
        self.device = device
        productID = UInt16(truncatingIfNeeded: (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0)
        serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        model = DeviceCatalog.model(forPID: productID)
    }

    public var displayName: String {
        model?.name ?? (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? String(format: "HyperX 0x%04X", productID)
    }

    func startListening() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { ctx, _, _, _, reportID, report, length in
                guard let ctx else { return }
                let mic = Unmanaged<HIDMic>.fromOpaque(ctx).takeUnretainedValue()
                var bytes = Array(UnsafeBufferPointer(start: report, count: length))
                // IOKit omits the ID byte for numbered reports in some paths; always put it at byte 0.
                if bytes.first != UInt8(truncatingIfNeeded: reportID), reportID != 0 { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
                mic.onRawReport?(bytes)
                if let ev = RealtekV7.parse(bytes) { mic.onEvent?(ev) }
            }, ctx)
    }

    deinit {
        // The callback holds an unretained pointer to self and writes into inputBuffer;
        // unregister it before either goes away.
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, nil, nil)
        inputBuffer.deallocate()
    }

    @discardableResult
    public func send(_ report: [UInt8]) -> IOReturn {
        precondition(report.count == RealtekV7.reportLength)
        return report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, $0.count)
        }
    }

    /// Ask for everything this model's UI shows; answers arrive via `onEvent`.
    public func requestState() {
        let features = model?.features ?? [.polarPattern, .monitoringMix, .lowCutFilter]
        send(RealtekV7.getReport(.inputMute))
        if features.contains(.polarPattern) { send(RealtekV7.getReport(.polarPattern)) }
        if features.contains(.monitoringMix) { send(RealtekV7.getReport(.monitoringBalanceLevel)) }
        if features.contains(.lowCutFilter) { send(RealtekV7.getReport(.globalFilters)) }
    }
}

/// Watches for HyperX mic control interfaces (VID 0x03F0, usage page 0xFF90).
public final class HIDMicManager: @unchecked Sendable {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    public private(set) var mics: [HIDMic] = []
    public var onChange: (([HIDMic]) -> Void)?

    public init() {}

    /// Returns the result of opening the HID manager; a sandbox or permission problem shows up here.
    @discardableResult
    public func start(runLoop: CFRunLoop = CFRunLoopGetMain()) -> IOReturn {
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Int(DeviceCatalog.vendorID),
            kIOHIDPrimaryUsagePageKey: Int(DeviceCatalog.controlUsagePage),
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<HIDMicManager>.fromOpaque(ctx!).takeUnretainedValue()
            me.added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<HIDMicManager>.fromOpaque(ctx!).takeUnretainedValue()
            me.mics.removeAll { $0.device == device }
            me.onChange?(me.mics)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func added(_ device: IOHIDDevice) {
        guard !mics.contains(where: { $0.device == device }) else { return }
        let mic = HIDMic(device: device)
        // Usage page 0xFF90 is shared with other HyperX protocols (QuadCast S lighting
        // lives on it too), so only talk Realtek V7 to the PIDs that use it.
        guard mic.model?.control == .realtekV7 else { return }
        mic.startListening()
        mics.append(mic)
        onChange?(mics)
    }
}
