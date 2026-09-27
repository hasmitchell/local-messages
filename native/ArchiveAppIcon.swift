import AppKit

// Flat teal-and-mint conversation bubbles, based on the approved Colour Chat
// concept in design/icon-concepts/flat/colour-chat-teal.png. Vector paths keep
// every icon size crisp and the build entirely local and reproducible.
// Paths use the concept's top-left coordinate system.
let upperBubble = CGMutablePath()
upperBubble.move(to: CGPoint(x: 626, y: 272))
upperBubble.addCurve(to: CGPoint(x: 775, y: 366), control1: CGPoint(x: 720, y: 255), control2: CGPoint(x: 752, y: 294))
upperBubble.addCurve(to: CGPoint(x: 807, y: 532), control1: CGPoint(x: 793, y: 418), control2: CGPoint(x: 808, y: 489))
upperBubble.addCurve(to: CGPoint(x: 740, y: 642), control1: CGPoint(x: 804, y: 590), control2: CGPoint(x: 784, y: 624))
upperBubble.addCurve(to: CGPoint(x: 433, y: 687), control1: CGPoint(x: 673, y: 659), control2: CGPoint(x: 507, y: 678))
upperBubble.addLine(to: CGPoint(x: 323, y: 776))
upperBubble.addCurve(to: CGPoint(x: 299, y: 756), control1: CGPoint(x: 307, y: 788), control2: CGPoint(x: 292, y: 776))
upperBubble.addLine(to: CGPoint(x: 316, y: 682))
upperBubble.addCurve(to: CGPoint(x: 232, y: 600), control1: CGPoint(x: 270, y: 668), control2: CGPoint(x: 244, y: 640))
upperBubble.addCurve(to: CGPoint(x: 215, y: 481), control1: CGPoint(x: 220, y: 562), control2: CGPoint(x: 215, y: 523))
upperBubble.addCurve(to: CGPoint(x: 322, y: 321), control1: CGPoint(x: 210, y: 397), control2: CGPoint(x: 246, y: 343))
upperBubble.addCurve(to: CGPoint(x: 626, y: 272), control1: CGPoint(x: 401, y: 302), control2: CGPoint(x: 550, y: 283))
upperBubble.closeSubpath()

let lowerBubble = CGMutablePath()
lowerBubble.move(to: CGPoint(x: 697, y: 516))
lowerBubble.addLine(to: CGPoint(x: 949, y: 558))
lowerBubble.addCurve(to: CGPoint(x: 1046, y: 702), control1: CGPoint(x: 1021, y: 571), control2: CGPoint(x: 1052, y: 636))
lowerBubble.addLine(to: CGPoint(x: 1024, y: 832))
lowerBubble.addCurve(to: CGPoint(x: 941, y: 943), control1: CGPoint(x: 1017, y: 895), control2: CGPoint(x: 1006, y: 915))
lowerBubble.addLine(to: CGPoint(x: 973, y: 985))
lowerBubble.addCurve(to: CGPoint(x: 955, y: 1004), control1: CGPoint(x: 982, y: 1004), control2: CGPoint(x: 965, y: 1016))
lowerBubble.addLine(to: CGPoint(x: 840, y: 925))
lowerBubble.addLine(to: CGPoint(x: 582, y: 894))
lowerBubble.addCurve(to: CGPoint(x: 478, y: 753), control1: CGPoint(x: 495, y: 880), control2: CGPoint(x: 472, y: 833))
lowerBubble.addCurve(to: CGPoint(x: 590, y: 527), control1: CGPoint(x: 483, y: 647), control2: CGPoint(x: 505, y: 557))
lowerBubble.addCurve(to: CGPoint(x: 697, y: 516), control1: CGPoint(x: 624, y: 504), control2: CGPoint(x: 655, y: 507))
lowerBubble.closeSubpath()

let teal = NSColor(srgbRed: 0.08, green: 0.43, blue: 0.38, alpha: 1).cgColor
let mint = NSColor(srgbRed: 0.34, green: 0.81, blue: 0.71, alpha: 1).cgColor
let overlap = NSColor(srgbRed: 12.0 / 255, green: 73.0 / 255, blue: 65.0 / 255, alpha: 1).cgColor
let ivory = NSColor(srgbRed: 1, green: 0.985, blue: 0.95, alpha: 1).cgColor

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for logicalSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = logicalSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        context.translateBy(x: 0, y: 1024)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(ivory)
        context.addPath(CGPath(roundedRect: CGRect(x: 60, y: 60, width: 904, height: 904), cornerWidth: 180, cornerHeight: 180, transform: nil))
        context.fillPath()
        context.translateBy(x: 60, y: 60)
        context.scaleBy(x: 904.0 / 1024, y: 904.0 / 1002)
        context.translateBy(x: -115, y: -133)
        context.setFillColor(teal)
        context.addPath(upperBubble)
        context.fillPath()
        context.setFillColor(mint)
        context.addPath(lowerBubble)
        context.fillPath()
        // Clip to the upper bubble to paint the exact intersection in dark teal.
        context.saveGState()
        context.addPath(upperBubble)
        context.clip()
        context.setFillColor(overlap)
        context.addPath(lowerBubble)
        context.fillPath()
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(logicalSize)x\(logicalSize)\(suffix).png"))
    }
}
