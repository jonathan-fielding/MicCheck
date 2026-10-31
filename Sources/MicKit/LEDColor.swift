import Foundation

/// RGB color for the QuadCast S LEDs.
public struct LEDColor: Equatable, Hashable, Sendable {
    /// Red channel (0–255).
    public let r: UInt8
    /// Green channel (0–255).
    public let g: UInt8
    /// Blue channel (0–255).
    public let b: UInt8

    /// Creates an RGB color.
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Black (off).
    public static let off = LEDColor(r: 0, g: 0, b: 0)

    /// Parses a color from a hex string (6 hex digits with optional leading `#`).
    ///
    /// Examples: `"FF0000"`, `"#00FF00"`, `"0000ff"`.
    public init?(hex: String) {
        var digits = hex
        if digits.hasPrefix("#") {
            digits = String(digits.dropFirst())
        }
        guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else {
            return nil
        }
        self.r = UInt8((rgb >> 16) & 0xFF)
        self.g = UInt8((rgb >> 8) & 0xFF)
        self.b = UInt8(rgb & 0xFF)
    }

    /// Returns the color as a 6-digit hex string (lowercase, no `#`).
    public var hex: String {
        String(format: "%02x%02x%02x", r, g, b)
    }

    /// Scales the color by a brightness factor (0.0–1.0).
    ///
    /// Each channel is multiplied by the brightness factor and rounded to the nearest integer.
    /// The factor is clamped to [0.0, 1.0].
    public func scaled(_ brightness: Double) -> LEDColor {
        let factor = max(0.0, min(1.0, brightness))
        let scale = { (v: UInt8) -> UInt8 in
            let scaled = Double(v) * factor
            let rounded = UInt8(scaled.rounded())
            return min(rounded, 255)
        }
        return LEDColor(r: scale(r), g: scale(g), b: scale(b))
    }
}
