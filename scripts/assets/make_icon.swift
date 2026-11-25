import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
let c = CGPoint(x: 512, y: 512)

// Night-sky background: deep indigo to charcoal (SyncDarkroom's dark theme).
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.17, 0.16, 0.26), rgb(0.05, 0.05, 0.08)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

// Six teardrop petals swirling clockwise like a lens aperture, blended with "screen" so overlaps glow.
let petals: [(CGFloat, CGFloat, CGFloat)] = [
    (1.00, 0.36, 0.30), (1.00, 0.62, 0.18), (0.98, 0.86, 0.26),
    (0.30, 0.82, 0.52), (0.24, 0.62, 1.00), (0.66, 0.42, 0.98),
]
ctx.setBlendMode(.screen)
for (i, p) in petals.enumerated() {
    let angle = CGFloat(i) * 2 * .pi / 6 + .pi / 2
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: angle)
    ctx.translateBy(x: 0, y: 165)
    ctx.rotate(by: -0.42)              // swirl
    // Teardrop: round end outward, pointed end toward the center.
    let path = CGMutablePath()
    let w: CGFloat = 128, h: CGFloat = 320
    path.move(to: CGPoint(x: 0, y: -h * 0.5))
    path.addCurve(to: CGPoint(x: w, y: h * 0.18), control1: CGPoint(x: w * 0.55, y: -h * 0.35), control2: CGPoint(x: w, y: -h * 0.05))
    path.addArc(center: CGPoint(x: 0, y: h * 0.18), radius: w, startAngle: 0, endAngle: .pi, clockwise: false)
    path.addCurve(to: CGPoint(x: 0, y: -h * 0.5), control1: CGPoint(x: -w, y: -h * 0.05), control2: CGPoint(x: -w * 0.55, y: -h * 0.35))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(p.0, p.1, p.2, 0.95), rgb(p.0 * 0.85, p.1 * 0.85, p.2 * 0.85, 0.75)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h * 0.6), end: CGPoint(x: 0, y: -h * 0.5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
ctx.setBlendMode(.normal)
// Small dark lens at the center.
let lens = CGGradient(colorsSpace: cs, colors: [rgb(0.28, 0.30, 0.42), rgb(0.06, 0.06, 0.10)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - 58, y: c.y - 58, width: 116, height: 116))
ctx.clip()
ctx.drawRadialGradient(lens, startCenter: CGPoint(x: c.x - 16, y: c.y + 20), startRadius: 0, endCenter: c, endRadius: 62, options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
for path in CommandLine.arguments.dropFirst() {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("ok")
