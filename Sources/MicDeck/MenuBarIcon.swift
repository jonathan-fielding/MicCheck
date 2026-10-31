import AppKit

/// Menu bar version of the app icon (capsule, grille, light band, stand), drawn at
/// 18 pt. The body follows the menu bar's label colour so it works in light and dark
/// menu bars; the light band shows the mic's current colours, or grey when off.
enum MenuBarIcon {
    static let defaultBand = [NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1),
                              NSColor(srgbRed: 1, green: 0.18, blue: 0.58, alpha: 1),
                              NSColor(srgbRed: 0.56, green: 0.27, blue: 1, alpha: 1)]

    /// `band`: colours across the light band (left → right); nil draws it neutral.
    /// `disconnected`: no microphone attached; the mic is drawn struck through.
    static func image(band: [NSColor]?, disconnected: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(band: disconnected ? nil : band, slashed: disconnected)
            return true
        }
        image.isTemplate = false   // keep the band's colour
        image.accessibilityDescription = disconnected ? "MicDeck: no microphone attached" : "MicDeck"
        return image
    }

    private static func draw(band: [NSColor]?, slashed: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Resolved against the menu bar's appearance; opaque so overlapping strokes don't darken.
        let ink = NSColor.labelColor.withAlphaComponent(1).cgColor
        // Knockouts below use the clear blend mode; a transparency layer keeps them from
        // erasing whatever the image is drawn on top of.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }
        ctx.setLineCap(.round)

        // Stand: base, stem, U-shaped yoke.
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: 5.5, y: 1.5)); ctx.addLine(to: CGPoint(x: 12.5, y: 1.5)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 9, y: 1.5)); ctx.addLine(to: CGPoint(x: 9, y: 3.6)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 3.9, y: 10))
        ctx.addCurve(to: CGPoint(x: 14.1, y: 10), control1: CGPoint(x: 3.9, y: 2.0), control2: CGPoint(x: 14.1, y: 2.0))
        ctx.strokePath()

        // Capsule, separated from the yoke by a thin knockout gap.
        let body = CGRect(x: 6.1, y: 6.2, width: 5.8, height: 11.3)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 2.9, cornerHeight: 2.9, transform: nil)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(bodyPath); ctx.setLineWidth(2.6); ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(bodyPath); ctx.setFillColor(ink); ctx.fillPath()

        ctx.saveGState()
        ctx.addPath(bodyPath); ctx.clip()
        // Grille slots, knocked out of the capsule.
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(0.75)
        for y in [12.9, 14.4, 15.9] as [CGFloat] {
            ctx.move(to: CGPoint(x: 7.6, y: y)); ctx.addLine(to: CGPoint(x: 10.4, y: y)); ctx.strokePath()
        }
        ctx.setBlendMode(.normal)
        // Light band.
        let bandRect = CGRect(x: body.minX, y: 9.1, width: body.width, height: 2.3)
        ctx.clip(to: bandRect)
        if let band {
            let colors = band.map(\.cgColor)
            let stops = colors.count == 1 ? [colors[0], colors[0]] : colors
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops as CFArray, locations: nil)!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: bandRect.minX, y: 0), end: CGPoint(x: bandRect.maxX, y: 0), options: [])
        } else {
            // Lighting off: a see-through band, readable on light and dark menu bars.
            ctx.setBlendMode(.clear); ctx.fill(bandRect)
            ctx.setBlendMode(.normal); ctx.setFillColor(ink.copy(alpha: 0.3)!); ctx.fill(bandRect)
        }
        ctx.restoreGState()

        if slashed {
            // Diagonal strike, like SF Symbols' "mic.slash": a knockout gap, then the line.
            let from = CGPoint(x: 2.5, y: 16.5), to = CGPoint(x: 15.5, y: 1.5)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(3.6)
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            ctx.restoreGState()
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(1.5)
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
        }
    }
}
