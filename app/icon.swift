// Draws the app icon (Claude orange + Codex teal, two chat bubbles) into an .iconset folder.
import Cocoa
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.shadowColor = NSColor(white: 0, alpha: 0.28); shadow.set()
    NSColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1).setFill(); shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.09, green: 0.085, blue: 0.08, alpha: 1), NSColor(red: 0.17, green: 0.16, blue: 0.15, alpha: 1)])!.draw(in: r, angle: 90)
    func bubble(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor, tailLeft: Bool) {
        let b = NSRect(x: r.minX + x * r.width, y: r.minY + y * r.height, width: w * r.width, height: h * r.height)
        let p = NSBezierPath(roundedRect: b, xRadius: b.height * 0.32, yRadius: b.height * 0.32)
        let t = NSBezierPath()
        let tx = tailLeft ? b.minX + b.width * 0.18 : b.maxX - b.width * 0.18
        t.move(to: NSPoint(x: tx - b.height * 0.14, y: b.minY + 1)); t.line(to: NSPoint(x: tx + (tailLeft ? -1 : 1) * b.height * 0.12, y: b.minY - b.height * 0.24)); t.line(to: NSPoint(x: tx + b.height * 0.16, y: b.minY + 1)); t.close()
        c.setFill(); p.fill(); t.fill()
        NSColor(white: 1, alpha: 0.9).setFill()
        for k in 0..<3 { let d = b.height * 0.15; NSBezierPath(ovalIn: NSRect(x: b.midX - d * 2.2 + CGFloat(k) * d * 1.6, y: b.midY - d / 2, width: d, height: d)).fill() }
    }
    bubble(0.12, 0.50, 0.56, 0.30, NSColor(red: 0.85, green: 0.45, blue: 0.20, alpha: 1), tailLeft: true)
    bubble(0.32, 0.16, 0.56, 0.30, NSColor(red: 0.16, green: 0.60, blue: 0.64, alpha: 1), tailLeft: false)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
