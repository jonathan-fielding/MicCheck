import Foundation

/// Protocol for sending USB HID feature reports to the lighting device.
public protocol LightingTransport: AnyObject {
    /// A short human-readable description of which path is in use, shown in the UI.
    var transportDescription: String { get }

    /// Sends a 64-byte HID feature report (report ID 0).
    func sendFeature(_ packet: [UInt8]) throws

    /// Closes the transport and releases resources.
    func close()
}
