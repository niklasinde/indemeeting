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
let unit = tile.width
let center = CGPoint(x: tile.midX, y: tile.midY)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func point(angle degrees: CGFloat, radius: CGFloat, from origin: CGPoint = center) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: origin.x + sin(radians) * radius, y: origin.y + cos(radians) * radius)
}

func continuousSquircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let exponent: CGFloat = 5
    let steps = 720
    for step in 0..<steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let x = pow(abs(cos(t)), 2 / exponent) * (cos(t) < 0 ? -1 : 1)
        let y = pow(abs(sin(t)), 2 / exponent) * (sin(t) < 0 ? -1 : 1)
        let p = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        step == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func withState(_ body: () -> Void) {
    ctx.saveGState()
    body()
    ctx.restoreGState()
}

func withShadow(blur: CGFloat, offset: CGFloat, color: CGColor, _ body: () -> Void) {
    withState {
        ctx.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur, color: color)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
    }
}

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func circle(_ c: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2), transform: nil)
}

func stroked(_ path: CGPath, width: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: join, miterLimit: 10)
}

func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat, cap: CGLineCap = .round) -> CGPath {
    let path = CGMutablePath()
    path.move(to: a)
    path.addLine(to: b)
    return stroked(path, width: width, cap: cap)
}

func glyphShadow(_ body: () -> Void) {
    withShadow(blur: unit * 0.045, offset: unit * 0.02, color: rgb(0x000000, 0.32), body)
}

func drawTile(top: CGColor, bottom: CGColor, glow: CGColor) {
    let shape = continuousSquircle(tile)
    withState {
        ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.012), blur: unit * 0.034, color: rgb(0x000000, 0.38))
        fill(shape, rgb(0x000000))
    }
    withState {
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: tile.minX, y: tile.maxY),
                               end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        ctx.drawRadialGradient(gradient([glow, glow.copy(alpha: 0)!]),
                               startCenter: CGPoint(x: tile.midX, y: tile.maxY), startRadius: 0,
                               endCenter: CGPoint(x: tile.midX, y: tile.maxY), endRadius: unit * 0.85, options: [])
        ctx.drawLinearGradient(gradient([rgb(0x000000, 0), rgb(0x000000, 0.22)]),
                               start: CGPoint(x: 0, y: tile.midY), end: CGPoint(x: 0, y: tile.minY), options: [])
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
        ctx.setLineWidth(unit * 0.008)
        ctx.strokePath()
    }
}

func drawVoiceDial() {
    drawTile(top: rgb(0x6A7BFF), bottom: rgb(0x2A1478), glow: rgb(0x9FB4FF, 0.45))
    let levels: [CGFloat] = [1.0, 0.35, 0.7, 0.25, 0.85, 0.4, 0.95, 0.3, 0.6, 0.2, 0.75, 0.45]
    let ring = unit * 0.315
    glyphShadow {
        for (index, level) in levels.enumerated() {
            let angle = CGFloat(index) * 30
            let half = unit * (0.025 + 0.075 * level)
            fill(line(point(angle: angle, radius: ring - half), point(angle: angle, radius: ring + half),
                      width: unit * 0.05), rgb(0xC3CCFF))
        }
        fill(line(center, point(angle: 300, radius: unit * 0.12), width: unit * 0.085), rgb(0xFFFFFF))
        fill(line(center, point(angle: 60, radius: unit * 0.18), width: unit * 0.066), rgb(0xFFFFFF))
        fill(circle(center, unit * 0.058), rgb(0xFF7A59))
        fill(circle(center, unit * 0.022), rgb(0xFFFFFF))
    }
}

drawVoiceDial()

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
