import AppKit

let size = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let canvas = CGFloat(size)
let inset = canvas * 0.0977
let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let squircle = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()
let gradient = NSGradient(colors: [NSColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1),
                                   NSColor(red: 0.62, green: 0.07, blue: 0.14, alpha: 1)])!
gradient.draw(in: tile, angle: -60)
ctx.restoreGState()

let heights: [CGFloat] = [0.16, 0.34, 0.54, 0.34, 0.16].map { $0 * tile.height * 0.78 }
let barWidth = tile.width * 0.075
let gap = tile.width * 0.058
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = tile.midX - total / 2
NSColor.white.setFill()
for height in heights {
    let bar = CGRect(x: x, y: tile.midY - height / 2 + tile.height * 0.04, width: barWidth, height: height)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

let dotRadius = tile.width * 0.043
let dotCenter = CGPoint(x: tile.maxX - tile.width * 0.17, y: tile.maxY - tile.height * 0.17)
NSColor.white.setFill()
NSBezierPath(ovalIn: CGRect(x: dotCenter.x - dotRadius * 1.45, y: dotCenter.y - dotRadius * 1.45,
                            width: dotRadius * 2.9, height: dotRadius * 2.9)).fill()
NSColor(red: 0.86, green: 0.1, blue: 0.16, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                            width: dotRadius * 2, height: dotRadius * 2)).fill()

NSGraphicsContext.restoreGraphicsState()

func writePNG(_ side: Int, to path: String) {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
writePNG(1024, to: "\(outDir)/AppIcon-1024.png")
for base in [16, 32, 128, 256, 512] {
    writePNG(base, to: "\(iconset)/icon_\(base)x\(base).png")
    writePNG(base * 2, to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
