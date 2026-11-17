// Gera AppIcon.icns: montanha + controle, em gradiente. Uso: swift icon.swift <pasta-saida>
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.42, green: 0.25, blue: 0.85, alpha: 1),
                        NSColor(red: 0.98, green: 0.45, blue: 0.40, alpha: 1)])!.draw(in: bg, angle: -60)
    // montanha
    let m = NSBezierPath()
    m.move(to: NSPoint(x: 170 * s, y: 300 * s))
    m.line(to: NSPoint(x: 430 * s, y: 690 * s))
    m.line(to: NSPoint(x: 540 * s, y: 540 * s))
    m.line(to: NSPoint(x: 640 * s, y: 760 * s))
    m.line(to: NSPoint(x: 854 * s, y: 300 * s))
    m.close()
    NSColor(white: 1, alpha: 0.92).setFill(); m.fill()
    // neve no pico
    let snow = NSBezierPath()
    snow.move(to: NSPoint(x: 595 * s, y: 662 * s))
    snow.line(to: NSPoint(x: 640 * s, y: 760 * s))
    snow.line(to: NSPoint(x: 686 * s, y: 662 * s))
    snow.line(to: NSPoint(x: 640 * s, y: 690 * s))
    snow.close()
    NSColor(red: 0.42, green: 0.25, blue: 0.85, alpha: 0.55).setFill(); snow.fill()
    // controle
    let pad = NSBezierPath(roundedRect: NSRect(x: 330 * s, y: 210 * s, width: 364 * s, height: 170 * s),
                           xRadius: 85 * s, yRadius: 85 * s)
    NSColor(red: 0.16, green: 0.12, blue: 0.30, alpha: 1).setFill(); pad.fill()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 395 * s, y: 285 * s, width: 70 * s, height: 20 * s)).fill()
    NSBezierPath(rect: NSRect(x: 420 * s, y: 260 * s, width: 20 * s, height: 70 * s)).fill()
    NSColor(red: 0.98, green: 0.45, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 585 * s, y: 300 * s, width: 40 * s, height: 40 * s)).fill()
    NSColor(red: 0.55, green: 0.85, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 625 * s, y: 255 * s, width: 40 * s, height: 40 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try! draw(CGFloat(px)).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
