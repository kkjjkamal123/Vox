// Draws the Vox app icon and writes Icon/AppIcon.icns.  Run: swift Icon/make-icon.swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func draw(_ ctx: CGContext, _ s: CGFloat) {
    let u = s / 1024
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

    // macOS icon grid: 824pt body, continuous-corner squircle.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = CGPath(roundedRect: body, cornerWidth: 186 * u, cornerHeight: 186 * u, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 28 * u, color: c(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(c(0.07, 0.07, 0.16)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Deep night background
    let bg = CGGradient(colorsSpace: space, colors: [c(0.13, 0.12, 0.33), c(0.04, 0.04, 0.12)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Aurora orb: soft colored lights blended additively
    let center = CGPoint(x: 512 * u, y: 500 * u)
    let lights: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
        (-110, 90, 330, c(0.20, 0.85, 1.00, 0.95)),   // cyan
        (120, 110, 320, c(0.78, 0.30, 1.00, 0.95)),   // violet
        (120, -110, 290, c(1.00, 0.33, 0.66, 0.90)),  // pink
        (-100, -120, 240, c(1.00, 0.55, 0.35, 0.45)), // warm accent
        (0, 0, 260, c(0.35, 0.40, 1.00, 0.95)),       // blue core
    ]
    ctx.setBlendMode(.screen)
    for (dx, dy, r, col) in lights {
        let p = CGPoint(x: center.x + dx * u, y: center.y + dy * u)
        let g = CGGradient(colorsSpace: space, colors: [col, col.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r * u, options: [])
    }
    // White-hot center
    let core = CGGradient(colorsSpace: space, colors: [c(1, 1, 1, 0.55), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(core, startCenter: center, startRadius: 0, endCenter: center, endRadius: 190 * u, options: [])
    ctx.setBlendMode(.normal)

    // Waveform bars
    let heights: [CGFloat] = [150, 290, 420, 290, 150]
    let w: CGFloat = 58, gap: CGFloat = 40
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30 * u, color: c(1, 1, 1, 0.65))
    for (i, h) in heights.enumerated() {
        let x = (512 - total / 2 + CGFloat(i) * (w + gap)) * u
        let r = CGRect(x: x, y: center.y - h / 2 * u, width: w * u, height: h * u)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: w / 2 * u, cornerHeight: w / 2 * u, transform: nil))
    }
    ctx.setFillColor(c(1, 1, 1, 0.97)); ctx.fillPath()
    ctx.restoreGState()

    // Glass: top sheen and a thin bright rim
    let sheen = CGGradient(colorsSpace: space, colors: [c(1, 1, 1, 0.22), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 60 * u), options: [])
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(c(1, 1, 1, 0.18)); ctx.setLineWidth(3 * u); ctx.strokePath()
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon")
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        draw(ctx, CGFloat(px))
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let dest = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote \(dir.appendingPathComponent("AppIcon.icns").path)")
