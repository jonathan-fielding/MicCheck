// Renders the app icon into Resources/AppIcon.icns.
//   swift Tools/make-icon.swift            (run from the package root)
// Drawn in a 1024-unit space and rendered natively at every iconset size.

import AppKit

func drawIcon(_ ctx: CGContext, _ px: CGFloat) {
    ctx.saveGState()
    ctx.scaleBy(x: px / 1024, y: px / 1024)
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: rgb, colors: stops.map { color($0.0) } as CFArray, locations: stops.map(\.1))!
    }

    // Background: macOS-style rounded square (824 pt tile inside the 1024 canvas).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.45))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x15161C)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(gradient([(0x2A2C36, 0), (0x101117, 1)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // soft coloured glow behind the mic head
    ctx.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: [color(0xFF2D55, 0.55), color(0x7B2DFF, 0.25), color(0x7B2DFF, 0)] as CFArray, locations: [0, 0.5, 1])!,
                           startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 600), endRadius: 380, options: [])
    ctx.restoreGState()

    // Stand: U-shaped yoke, stem and base.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xC9CCD6))
    ctx.setLineWidth(34)
    let yoke = CGMutablePath()
    yoke.move(to: CGPoint(x: 352, y: 560))
    yoke.addCurve(to: CGPoint(x: 672, y: 560), control1: CGPoint(x: 352, y: 330), control2: CGPoint(x: 672, y: 330))
    ctx.addPath(yoke); ctx.strokePath()
    ctx.move(to: CGPoint(x: 512, y: 388)); ctx.addLine(to: CGPoint(x: 512, y: 262)); ctx.strokePath()
    ctx.setLineWidth(40)
    ctx.move(to: CGPoint(x: 400, y: 244)); ctx.addLine(to: CGPoint(x: 624, y: 244)); ctx.strokePath()

    // Glow from the light band, drawn behind the capsule so it only bleeds outward.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: color(0xFF2D95, 0.95))
    ctx.setFillColor(color(0xFF2D95))
    ctx.fill(CGRect(x: 406, y: 552, width: 212, height: 64))
    ctx.restoreGState()

    // Mic capsule.
    let body = CGRect(x: 402, y: 430, width: 220, height: 400)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 110, cornerHeight: 110, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.5))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x30323C)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([(0x5A5D6B, 0), (0x2B2D36, 0.55), (0x1C1D24, 1)]), start: CGPoint(x: 402, y: 640), end: CGPoint(x: 622, y: 640), options: [])

    // Grille: horizontal slots on the upper half.
    ctx.setStrokeColor(color(0x0E0F14, 0.85))
    ctx.setLineWidth(10)
    var y: CGFloat = 790
    while y > 640 {
        ctx.move(to: CGPoint(x: 432, y: y)); ctx.addLine(to: CGPoint(x: 592, y: y)); ctx.strokePath()
        y -= 26
    }

    // Light band (the QuadCast's glow), red → magenta → violet.
    let band = CGRect(x: 402, y: 548, width: 220, height: 72)
    ctx.addRect(band); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFF3B30, 0), (0xFF2D95, 0.5), (0x8E44FF, 1)]), start: CGPoint(x: 402, y: 584), end: CGPoint(x: 622, y: 584), options: [])
    ctx.restoreGState()

    // Specular highlight on the capsule.
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.setFillColor(color(0xFFFFFF, 0.10))
    ctx.fillEllipse(in: CGRect(x: 424, y: 640, width: 46, height: 170))
    ctx.restoreGState()

    // Thin rim on the capsule.
    ctx.addPath(bodyPath); ctx.setStrokeColor(color(0xFFFFFF, 0.12)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.interpolationQuality = .high
        drawIcon(ctx, CGFloat(px))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
print("wrote \(iconset.path)")
