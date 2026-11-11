// Renders Resources/AppIcon.icns: a stylised end mill cutting a wood block.
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // Background squircle
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.15, blue: 0.2, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)])!.draw(in: bg, angle: -90)
    // Wood block
    let block = NSBezierPath(roundedRect: NSRect(x: 220 * s, y: 230 * s, width: 584 * s, height: 220 * s), xRadius: 26 * s, yRadius: 26 * s)
    NSGradient(colors: [NSColor(red: 0.93, green: 0.74, blue: 0.47, alpha: 1), NSColor(red: 0.74, green: 0.52, blue: 0.3, alpha: 1)])!.draw(in: block, angle: -90)
    // Carved groove (toolpath)
    ctx.setStrokeColor(NSColor(red: 0.2, green: 0.85, blue: 1, alpha: 1).cgColor)
    ctx.setLineWidth(18 * s)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 280 * s, y: 380 * s))
    ctx.addCurve(to: CGPoint(x: 512 * s, y: 380 * s), control1: CGPoint(x: 340 * s, y: 300 * s), control2: CGPoint(x: 450 * s, y: 300 * s))
    ctx.strokePath()
    // End mill
    let shank = NSBezierPath(roundedRect: NSRect(x: 462 * s, y: 600 * s, width: 100 * s, height: 250 * s), xRadius: 14 * s, yRadius: 14 * s)
    NSGradient(colors: [NSColor(white: 0.55, alpha: 1), NSColor(white: 0.95, alpha: 1), NSColor(white: 0.6, alpha: 1)])!.draw(in: shank, angle: 0)
    let flute = NSBezierPath(rect: NSRect(x: 472 * s, y: 395 * s, width: 80 * s, height: 215 * s))
    NSGradient(colors: [NSColor(white: 0.45, alpha: 1), NSColor(white: 0.9, alpha: 1), NSColor(white: 0.5, alpha: 1)])!.draw(in: flute, angle: 0)
    ctx.setStrokeColor(NSColor(white: 0.25, alpha: 0.9).cgColor)
    ctx.setLineWidth(9 * s)
    for i in 0..<5 {
        let y = (410 + CGFloat(i) * 42) * s
        ctx.move(to: CGPoint(x: 472 * s, y: y)); ctx.addLine(to: CGPoint(x: 552 * s, y: y + 34 * s)); ctx.strokePath()
    }
    // Chips (swarf!)
    ctx.setStrokeColor(NSColor(red: 0.95, green: 0.78, blue: 0.5, alpha: 1).cgColor)
    ctx.setLineWidth(12 * s)
    for (x, y, r) in [(610.0, 470.0, 30.0), (660.0, 530.0, 22.0), (395.0, 500.0, 26.0), (350.0, 560.0, 18.0)] {
        ctx.addArc(center: CGPoint(x: x * s, y: y * s), radius: r * s, startAngle: 0.3, endAngle: 4.2, clockwise: false)
        ctx.strokePath()
    }
    img.unlockFocus()
    return img
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("Wrote \(out.path)")
