import AppKit

// A code-drawn icon keeps the prototype's build entirely local and reproducible.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for logicalSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = logicalSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        NSColor(calibratedRed: 0.08, green: 0.43, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 200, yRadius: 200).fill()
        NSColor.white.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: NSRect(x: 160, y: 365, width: 570, height: 420), xRadius: 80, yRadius: 80).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 245, y: 285, width: 570, height: 420), xRadius: 80, yRadius: 80).fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 670, y: 330))
        tail.line(to: NSPoint(x: 775, y: 190))
        tail.line(to: NSPoint(x: 765, y: 355))
        tail.close()
        tail.fill()
        NSColor(calibratedRed: 0.08, green: 0.43, blue: 0.38, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: NSRect(x: 335, y: 525, width: 365, height: 38), xRadius: 19, yRadius: 19).fill()
        NSBezierPath(roundedRect: NSRect(x: 335, y: 430, width: 260, height: 38), xRadius: 19, yRadius: 19).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(logicalSize)x\(logicalSize)\(suffix).png"))
    }
}
