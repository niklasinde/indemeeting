import AppKit

// Renders the iOS app icon: a full-bleed 1024 square (iOS rounds it) with the same bars and recording dot as the Mac icon.
// Usage: swift scripts/make-ios-icon.swift ios/MeetingRecorderPhone/Assets.xcassets/AppIcon.appiconset/icon-1024.png
let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
NSGradient(colors: [NSColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1), NSColor(red: 0.62, green: 0.07, blue: 0.14, alpha: 1)])!.draw(in: canvas, angle: -60)

let heights: [CGFloat] = [0.16, 0.34, 0.54, 0.34, 0.16].map { $0 * canvas.height * 0.62 }
let barWidth = canvas.width * 0.06
let gap = canvas.width * 0.046
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = canvas.midX - total / 2
NSColor.white.setFill()
for height in heights {
    let bar = CGRect(x: x, y: canvas.midY - height / 2 + canvas.height * 0.03, width: barWidth, height: height)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}
let radius = canvas.width * 0.034
let center = CGPoint(x: canvas.maxX - canvas.width * 0.2, y: canvas.maxY - canvas.height * 0.2)
NSColor.white.setFill()
NSBezierPath(ovalIn: CGRect(x: center.x - radius * 1.45, y: center.y - radius * 1.45, width: radius * 2.9, height: radius * 2.9)).fill()
NSColor(red: 0.86, green: 0.1, blue: 0.16, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
