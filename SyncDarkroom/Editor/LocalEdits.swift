import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PencilKit
import UIKit

// MARK: - Model

/// A point normalized to an image frame: 0…1, origin at the top-left.
struct NPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct StrokePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    /// Pencil pressure 0…1 (1 for finger).
    var p: Double
}

struct BrushStroke: Codable, Equatable, Sendable {
    var points: [StrokePoint] = []
    /// Radius as a fraction of the image's shorter side.
    var radius: Double
    var softness: Double
    var flow: Double
    var erase: Bool
}

/// A local adjustment area. Coordinates are in the original photo's frame
/// (before crop/straighten), so the mask stays on its subject when you re-crop.
struct MaskLayer: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case brush, linear, radial
        var title: String {
            switch self {
            case .brush: "Brush"
            case .linear: "Linear Gradient"
            case .radial: "Radial Gradient"
            }
        }
        var systemImage: String {
            switch self {
            case .brush: "paintbrush.pointed"
            case .linear: "square.bottomhalf.filled"
            case .radial: "circle.dashed.inset.filled"
            }
        }
    }

    static let adjustableKeys: [Adjustment] = [
        .exposure, .contrast, .highlights, .shadows, .whites, .blacks,
        .temperature, .tint, .saturation, .clarity, .sharpness,
    ]

    var id = UUID()
    var kind: Kind
    var name: String
    var adjustments: [String: Double] = [:]
    var inverted = false
    var strokes: [BrushStroke] = []
    var linearStart = NPoint(x: 0.5, y: 0.25)
    var linearEnd = NPoint(x: 0.5, y: 0.6)
    var center = NPoint(x: 0.5, y: 0.5)
    /// Fractions of the photo's width / height.
    var radiusX = 0.25
    var radiusY = 0.25
    var feather = 0.5

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .brush
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.title
        adjustments = try c.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        strokes = try c.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
        linearStart = try c.decodeIfPresent(NPoint.self, forKey: .linearStart) ?? NPoint(x: 0.5, y: 0.25)
        linearEnd = try c.decodeIfPresent(NPoint.self, forKey: .linearEnd) ?? NPoint(x: 0.5, y: 0.6)
        center = try c.decodeIfPresent(NPoint.self, forKey: .center) ?? NPoint(x: 0.5, y: 0.5)
        radiusX = try c.decodeIfPresent(Double.self, forKey: .radiusX) ?? 0.25
        radiusY = try c.decodeIfPresent(Double.self, forKey: .radiusY) ?? 0.25
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5
    }

    subscript(_ a: Adjustment) -> Double {
        get { adjustments[a.rawValue] ?? 0 }
        set { adjustments[a.rawValue] = abs(newValue) < 0.0001 ? nil : newValue }
    }
}

/// A spot-removal circle: `target` is covered with pixels from `source`.
struct HealSpot: Codable, Equatable, Sendable, Identifiable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case heal, clone
        var title: String { self == .heal ? "Heal" : "Clone" }
    }

    var id = UUID()
    var mode: Mode
    var target: NPoint
    var source: NPoint
    /// Fraction of the photo's shorter side.
    var radius: Double
    var feather = 0.5
}

struct RGBAColor: Codable, Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    static let red = RGBAColor(r: 1, g: 0.23, b: 0.19)
}

struct TextItem: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    /// Center of the text, in the final (cropped) frame.
    var position: NPoint
    /// Font size as a fraction of the final image width.
    var size: Double
    var color: RGBAColor
    var bold = true
}

struct ShapeItem: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case rectangle, ellipse, line, arrow
        var title: String { rawValue.capitalized }
        var systemImage: String {
            switch self {
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var start: NPoint
    var end: NPoint
    var color: RGBAColor
    /// Stroke width as a fraction of the final image width.
    var lineWidth: Double
}

/// Annotations drawn on top of the finished (cropped) picture.
struct Markup: Codable, Equatable, Sendable {
    /// PencilKit drawing in a coordinate space where the final image is `referenceWidth` wide.
    var drawing: Data?
    var texts: [TextItem] = []
    var shapes: [ShapeItem] = []

    static let referenceWidth: CGFloat = 1000

    var isEmpty: Bool {
        texts.isEmpty && shapes.isEmpty && (drawing.flatMap { try? PKDrawing(data: $0) }?.strokes.isEmpty ?? true)
    }

    init(drawing: Data? = nil, texts: [TextItem] = [], shapes: [ShapeItem] = []) {
        self.drawing = drawing
        self.texts = texts
        self.shapes = shapes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drawing = try c.decodeIfPresent(Data.self, forKey: .drawing)
        texts = try c.decodeIfPresent([TextItem].self, forKey: .texts) ?? []
        shapes = try c.decodeIfPresent([ShapeItem].self, forKey: .shapes) ?? []
    }
}

// MARK: - Orientation mapping

extension Geometry {
    private var turns: Int { ((quarterTurns % 4) + 4) % 4 }

    /// Point in the rotated/flipped frame shown while masking → point in the original photo.
    func sourcePoint(fromOriented p: NPoint) -> NPoint {
        var q = p
        for _ in 0..<turns { q = NPoint(x: q.y, y: 1 - q.x) }
        if flipVertical { q.y = 1 - q.y }
        if flipHorizontal { q.x = 1 - q.x }
        return q
    }

    /// Point in the original photo → point in the rotated/flipped frame.
    func orientedPoint(fromSource p: NPoint) -> NPoint {
        var q = p
        if flipHorizontal { q.x = 1 - q.x }
        if flipVertical { q.y = 1 - q.y }
        for _ in 0..<turns { q = NPoint(x: 1 - q.y, y: q.x) }
        return q
    }

    var swapsAxes: Bool { turns % 2 == 1 }
}

// MARK: - Rendering

enum LocalRenderer {
    private static func ci(_ p: NPoint, _ e: CGRect) -> CGPoint {
        CGPoint(x: p.x * e.width, y: (1 - p.y) * e.height)
    }

    // MARK: Heal

    static func applyHeals(_ input: CIImage, _ spots: [HealSpot]) -> CIImage {
        let extent = input.extent
        let minDim = min(extent.width, extent.height)
        var current = input
        for spot in spots {
            let r = max(2, spot.radius * minDim)
            let target = ci(spot.target, extent), source = ci(spot.source, extent)
            let shift = CGAffineTransform(translationX: target.x - source.x, y: target.y - source.y)
            let clamped = current.clampedToExtent()
            var patch = clamped.transformed(by: shift)

            if spot.mode == .heal {
                // Keep the source's texture but take the low-frequency color/brightness
                // from around the target: patch + blur(target) − blur(patch).
                let sigma = Double(max(2, r * 0.6))
                let targetLow = clamped.applyingGaussianBlur(sigma: sigma)
                let patchLow = patch.applyingGaussianBlur(sigma: sigma)
                let zeroAlpha = CIVector(x: 0, y: 0, z: 0, w: 0)
                let lowPlus = targetLow.applyingFilter("CIColorMatrix", parameters: ["inputAVector": zeroAlpha])
                let lowMinus = patchLow.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
                    "inputAVector": zeroAlpha,
                ])
                patch = lowPlus.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: patch])
                    .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: lowMinus])
            }

            let mask = CIFilter.radialGradient()
            mask.center = target
            mask.radius0 = Float(r * (1 - max(0.05, spot.feather) * 0.8))
            mask.radius1 = Float(r)
            mask.color0 = .white
            mask.color1 = .black
            guard let maskImage = mask.outputImage else { continue }
            current = patch.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: current,
                kCIInputMaskImageKey: maskImage,
            ]).cropped(to: extent)
        }
        return current
    }

    // MARK: Masks

    static func applyMasks(_ input: CIImage, _ masks: [MaskLayer], scale: CGFloat, highlight: UUID?) -> CIImage {
        let extent = input.extent
        var current = input
        for layer in masks {
            guard let mask = maskImage(layer, extent: extent) else { continue }
            if !layer.adjustments.isEmpty {
                var recipe = EditRecipe()
                recipe.adjustments = layer.adjustments
                let adjusted = Renderer.applyTone(current, recipe, scale: scale)
                current = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: current,
                    kCIInputMaskImageKey: mask,
                ]).cropped(to: extent)
            }
        }
        // Red tint showing where the selected mask applies.
        if let highlight, let layer = masks.first(where: { $0.id == highlight }),
           let mask = maskImage(layer, extent: extent) {
            let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1)).cropped(to: extent)
            let half = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
            ])
            current = red.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: current,
                kCIInputMaskImageKey: half,
            ]).cropped(to: extent)
        }
        return current
    }

    /// White where the mask applies, black elsewhere.
    static func maskImage(_ layer: MaskLayer, extent: CGRect) -> CIImage? {
        var mask: CIImage?
        switch layer.kind {
        case .linear:
            let f = CIFilter.linearGradient()
            f.point0 = ci(layer.linearStart, extent)
            f.point1 = ci(layer.linearEnd, extent)
            f.color0 = .white
            f.color1 = .black
            mask = f.outputImage
        case .radial:
            let unit: CGFloat = 1000
            let f = CIFilter.radialGradient()
            f.center = .zero
            f.radius0 = Float(unit * (1 - max(0.02, min(0.98, layer.feather))))
            f.radius1 = Float(unit)
            f.color0 = .white
            f.color1 = .black
            let c = ci(layer.center, extent)
            let sx = max(1, layer.radiusX * extent.width) / unit
            let sy = max(1, layer.radiusY * extent.height) / unit
            mask = f.outputImage?
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
        case .brush:
            mask = BrushRasterizer.shared.mask(for: layer, extent: extent)
        }
        guard var result = mask?.cropped(to: extent) else { return nil }
        if layer.inverted { result = result.applyingFilter("CIColorInvert").cropped(to: extent) }
        return result
    }
}

/// Paints brush strokes into a grayscale bitmap, caching everything but the last stroke
/// so painting stays responsive as strokes accumulate.
final class BrushRasterizer: @unchecked Sendable {
    static let shared = BrushRasterizer()

    private let lock = NSLock()
    private var cache: [UUID: (strokes: [BrushStroke], size: CGSize, image: CGImage)] = [:]

    func mask(for layer: MaskLayer, extent: CGRect) -> CIImage? {
        let maxSide: CGFloat = 1024
        let s = min(1, maxSide / max(extent.width, extent.height))
        let size = CGSize(width: max(1, (extent.width * s).rounded()), height: max(1, (extent.height * s).rounded()))
        guard let image = raster(layer, size: size) else { return nil }
        return CIImage(cgImage: image)
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height))
    }

    private func raster(_ layer: MaskLayer, size: CGSize) -> CGImage? {
        let strokes = layer.strokes
        let committed = Array(strokes.dropLast())

        lock.lock()
        let cached = cache[layer.id]
        lock.unlock()

        let base: CGImage?
        if let cached, cached.size == size, cached.strokes == committed {
            base = cached.image
        } else {
            base = draw(committed, size: size, onto: nil)
            if let base {
                lock.lock()
                cache[layer.id] = (committed, size, base)
                lock.unlock()
            }
        }
        guard let last = strokes.last else { return base ?? draw([], size: size, onto: nil) }
        return draw([last], size: size, onto: base)
    }

    private func draw(_ strokes: [BrushStroke], size: CGSize, onto base: CGImage?) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        if let base { ctx.draw(base, in: rect) } else {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(rect)
        }
        let minDim = min(size.width, size.height)
        let gray = CGColorSpaceCreateDeviceGray()
        for stroke in strokes {
            let value: CGFloat = stroke.erase ? 0 : 1
            // ~4 dabs overlap at any spot; scale alpha so they add up to `flow`.
            let dabAlpha = CGFloat(1 - pow(1 - min(0.99, stroke.flow), 0.25))
            let hard = CGFloat(1 - stroke.softness)
            guard let gradient = CGGradient(
                colorsSpace: gray,
                colors: [CGColor(gray: value, alpha: dabAlpha), CGColor(gray: value, alpha: dabAlpha),
                         CGColor(gray: value, alpha: 0)] as CFArray,
                locations: [0, max(0, min(0.99, hard)), 1]
            ) else { continue }

            func dab(_ p: StrokePoint) {
                let r = max(0.5, stroke.radius * minDim * (0.35 + 0.65 * p.p))
                let c = CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
                ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }

            guard var previous = stroke.points.first else { continue }
            dab(previous)
            for point in stroke.points.dropFirst() {
                let dx = (point.x - previous.x) * size.width, dy = (point.y - previous.y) * size.height
                let dist = hypot(dx, dy)
                let r = max(0.5, stroke.radius * minDim * (0.35 + 0.65 * point.p))
                let step = max(1, r * 0.25)
                if dist >= step {
                    let n = Int(dist / step)
                    for i in 1...n {
                        let t = Double(i) / Double(n)
                        dab(StrokePoint(x: previous.x + (point.x - previous.x) * t,
                                        y: previous.y + (point.y - previous.y) * t,
                                        p: previous.p + (point.p - previous.p) * t))
                    }
                    previous = point
                }
            }
        }
        return ctx.makeImage()
    }
}

/// Draws markup (PencilKit ink, shapes, text) into a transparent image of the final frame's size.
enum MarkupRenderer {
    static func image(_ markup: Markup, size: CGSize, includeDrawing: Bool = true) -> UIImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            for shape in markup.shapes { draw(shape, in: cg, size: size) }
            if includeDrawing, let data = markup.drawing, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty {
                let scale = size.width / Markup.referenceWidth
                let scaled = drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
                var ink: UIImage?
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = scaled.image(from: CGRect(origin: .zero, size: size), scale: 1)
                }
                ink?.draw(in: CGRect(origin: .zero, size: size))
            }
            for text in markup.texts { draw(text, size: size) }
        }
    }

    static func draw(_ shape: ShapeItem, in cg: CGContext, size: CGSize) {
        let a = CGPoint(x: shape.start.x * size.width, y: shape.start.y * size.height)
        let b = CGPoint(x: shape.end.x * size.width, y: shape.end.y * size.height)
        let width = max(1, shape.lineWidth * size.width)
        cg.saveGState()
        cg.setStrokeColor(shape.color.uiColor.cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch shape.kind {
        case .rectangle: cg.stroke(rect)
        case .ellipse: cg.strokeEllipse(in: rect)
        case .line, .arrow:
            cg.move(to: a)
            cg.addLine(to: b)
            cg.strokePath()
            if shape.kind == .arrow {
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = max(width * 3.5, 12)
                for side in [-1.0, 1.0] {
                    let theta = angle + .pi + side * .pi / 7
                    cg.move(to: b)
                    cg.addLine(to: CGPoint(x: b.x + head * cos(theta), y: b.y + head * sin(theta)))
                }
                cg.strokePath()
            }
        }
        cg.restoreGState()
    }

    static func draw(_ text: TextItem, size: CGSize) {
        let font = UIFont.systemFont(ofSize: max(4, text.size * size.width), weight: text.bold ? .bold : .regular)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = font.pointSize * 0.08
        shadow.shadowOffset = CGSize(width: 0, height: font.pointSize * 0.03)
        let attributed = NSAttributedString(string: text.text, attributes: [
            .font: font, .foregroundColor: text.color.uiColor, .shadow: shadow,
        ])
        let bounds = attributed.boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin], context: nil)
        let origin = CGPoint(x: text.position.x * size.width - bounds.width / 2,
                             y: text.position.y * size.height - bounds.height / 2)
        attributed.draw(with: CGRect(origin: origin, size: bounds.size), options: [.usesLineFragmentOrigin], context: nil)
    }

    /// The markup as a CIImage covering `extent` (rendered at most `maxSide` px, then scaled).
    static func overlay(_ markup: Markup, extent: CGRect, maxSide: CGFloat = 6000) -> CIImage? {
        let s = min(1, maxSide / max(extent.width, extent.height))
        let size = CGSize(width: (extent.width * s).rounded(), height: (extent.height * s).rounded())
        guard let cg = image(markup, size: size)?.cgImage else { return nil }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height))
    }
}

// MARK: - Automatic heal source

/// Small RGB copy of the photo used to pick a good heal source.
struct PixelSampler: @unchecked Sendable {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(_ image: CIImage, maxSide: CGFloat = 320) {
        let e = image.extent
        let s = min(1, maxSide / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = max(1, Int((e.width * s).rounded())), h = max(1, Int((e.height * s).rounded()))
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        Renderer.context.render(small, toBitmap: &buffer, rowBytes: w * 4,
                                bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        width = w
        height = h
        pixels = buffer
    }

    /// RGB at a normalized point (top-left origin); nil outside the image.
    func color(_ p: NPoint) -> SIMD3<Float>? {
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return nil }
        let x = min(width - 1, Int(p.x * Double(width)))
        let y = min(height - 1, Int(p.y * Double(height)))
        // Bitmap rows from render(toBitmap:) start at the top.
        let i = (y * width + x) * 4
        return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
    }

    /// Picks the nearby spot whose surroundings best match the target's and whose
    /// own content is calm (so we don't copy another object).
    func bestSource(for target: NPoint, radius: Double, aspect: Double) -> NPoint? {
        // radius is a fraction of the shorter side; convert to x/y fractions.
        let rx = aspect >= 1 ? radius / aspect : radius
        let ry = aspect >= 1 ? radius : radius * aspect
        func ring(_ c: NPoint, scale: Double, count: Int) -> [SIMD3<Float>]? {
            var out = [SIMD3<Float>]()
            for i in 0..<count {
                let a = Double(i) / Double(count) * 2 * .pi
                guard let col = color(NPoint(x: c.x + cos(a) * rx * scale, y: c.y + sin(a) * ry * scale)) else { return nil }
                out.append(col)
            }
            return out
        }
        guard let targetRing = ring(target, scale: 1.35, count: 24) else { return nil }

        var best: (NPoint, Float)?
        for distance in [2.3, 3.4] {
            for k in 0..<8 {
                let a = Double(k) / 8 * 2 * .pi
                let c = NPoint(x: target.x + cos(a) * rx * distance, y: target.y + sin(a) * ry * distance)
                guard let candidateRing = ring(c, scale: 1.35, count: 24),
                      let inner1 = ring(c, scale: 0.5, count: 12),
                      let inner2 = ring(c, scale: 0.9, count: 16),
                      let center = color(c) else { continue }
                var match: Float = 0
                for i in 0..<targetRing.count {
                    let d: SIMD3<Float> = targetRing[i] - candidateRing[i]
                    match += abs(d.x) + abs(d.y) + abs(d.z)
                }
                match /= Float(targetRing.count)
                let inner: [SIMD3<Float>] = inner1 + inner2 + [center]
                var sum = SIMD3<Float>(repeating: 0)
                for c in inner { sum += c }
                let mean: SIMD3<Float> = sum / Float(inner.count)
                var busy: Float = 0
                for c in inner {
                    let d: SIMD3<Float> = c - mean
                    busy += abs(d.x) + abs(d.y) + abs(d.z)
                }
                busy /= Float(inner.count)
                let score = match + busy * 1.5 + Float(distance) * 0.01
                if score < (best?.1 ?? .infinity) { best = (c, score) }
            }
        }
        return best?.0
    }
}
