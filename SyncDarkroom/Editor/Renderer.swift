import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Turns an `EditRecipe` into a Core Image graph. The same code renders the
/// on-screen preview (downsampled, `scale` < 1) and the full-resolution export.
enum Renderer {
    static let context = CIContext(options: [
        .cacheIntermediates: false,
        .name: "SyncDarkroom",
    ])

    enum GeometryMode: Sendable {
        /// Everything, including the crop (normal view and export).
        case full
        /// Straightened/perspective-corrected but not cropped (Crop panel).
        case uncropped
        /// Only rotation and flips (Masks / Heal panels, which edit in the photo's own frame).
        case orientOnly
    }

    /// Order: heal → global tone → masks → geometry → vignette → markup.
    /// - Parameter scale: preview width ÷ full-resolution width, used to size blur radii.
    static func render(_ source: CIImage, recipe: EditRecipe, scale: CGFloat,
                       geometry: GeometryMode = .full, includeMarkup: Bool = true,
                       highlightMask: UUID? = nil) -> CIImage {
        var image = source.normalizedOrigin()
        if let heals = recipe.heals, !heals.isEmpty { image = LocalRenderer.applyHeals(image, heals) }
        image = applyTone(image, recipe, scale: scale)
        if let masks = recipe.masks, !masks.isEmpty {
            image = LocalRenderer.applyMasks(image, masks, scale: scale, highlight: highlightMask)
        }
        image = applyGeometry(image, recipe.geometry, mode: geometry)
        if geometry != .orientOnly { image = applyVignette(image, amount: recipe[.vignette]) }
        image = image.cropped(to: CGRect(origin: .zero, size: image.extent.size.rounded())).normalizedOrigin()
        if includeMarkup, geometry == .full, let markup = recipe.markup, !markup.isEmpty,
           let overlay = MarkupRenderer.overlay(markup, extent: image.extent) {
            image = overlay.composited(over: image).cropped(to: image.extent)
        }
        return image
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func makeUIImage(_ image: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Tone & color

    static func applyTone(_ input: CIImage, _ r: EditRecipe, scale: CGFloat) -> CIImage {
        let extent = input.extent
        var img = input

        let temperature = r[.temperature], tint = r[.tint]
        if temperature != 0 || tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500 + temperature * 35, y: tint * 0.8)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage ?? img
        }

        if r[.exposure] != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(r[.exposure])
            img = f.outputImage ?? img
        }

        let highlights = r[.highlights], shadows = r[.shadows]
        if highlights < 0 || shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img.clampedToExtent()
            f.highlightAmount = Float(1 + min(highlights, 0) / 100)
            f.shadowAmount = Float(shadows / 100)
            f.radius = Float(max(1, 25 * scale))
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        let contrast = r[.contrast] / 100
        let whites = r[.whites] / 100
        let blacks = r[.blacks] / 100
        let highlightBoost = max(highlights, 0) / 100
        if contrast != 0 || whites != 0 || blacks != 0 || highlightBoost != 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = img
            f.point0 = blacks >= 0 ? CGPoint(x: 0, y: blacks * 0.15) : CGPoint(x: -blacks * 0.12, y: 0)
            f.point1 = CGPoint(x: 0.25, y: 0.25 - contrast * 0.07)
            f.point2 = CGPoint(x: 0.5, y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: min(0.98, 0.75 + contrast * 0.07 + highlightBoost * 0.1))
            f.point4 = whites >= 0 ? CGPoint(x: 1 - whites * 0.12, y: 1) : CGPoint(x: 1, y: 1 + whites * 0.15)
            img = f.outputImage ?? img
        }

        if let curves = r.curves, !curves.isIdentity {
            let f = CIFilter.colorCurves()
            f.inputImage = img
            f.curvesData = curves.lutData()
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = sRGB
            img = f.outputImage ?? img
        }

        if let hsl = r.hslValues {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(HSLCube.size)
            f.cubeData = HSLCube.data(for: hsl)
            f.colorSpace = sRGB
            img = f.outputImage ?? img
        }

        if r[.vibrance] != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(r[.vibrance] / 100)
            img = f.outputImage ?? img
        }

        if r[.saturation] != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(1 + r[.saturation] / 100)
            f.contrast = 1
            f.brightness = 0
            img = f.outputImage ?? img
        }

        let clarity = r[.clarity] / 100
        if clarity > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img.clampedToExtent()
            f.radius = Float(max(1, 40 * scale))
            f.intensity = Float(clarity * 0.6)
            img = (f.outputImage ?? img).cropped(to: extent)
        } else if clarity < 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = img.clampedToExtent()
            blur.radius = Float(max(0.5, 12 * scale))
            if let blurred = blur.outputImage?.cropped(to: extent) {
                let mix = CIFilter.dissolveTransition()
                mix.inputImage = img
                mix.targetImage = blurred
                mix.time = Float(-clarity * 0.6)
                img = mix.outputImage ?? img
            }
        }

        if r[.noiseReduction] > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = img.clampedToExtent()
            f.noiseLevel = Float(r[.noiseReduction] / 100 * 0.06)
            f.sharpness = 0.4
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        if r[.sharpness] > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img.clampedToExtent()
            f.sharpness = Float(r[.sharpness] / 100 * 1.5)
            f.radius = Float(max(0.5, 1.7 * min(1, scale * 2)))
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        return img
    }

    private static func applyVignette(_ input: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return input }
        let extent = input.extent
        let f = CIFilter.vignetteEffect()
        f.inputImage = input
        f.center = CGPoint(x: extent.midX, y: extent.midY)
        f.radius = Float(hypot(extent.width, extent.height) / 2 * 0.85)
        f.intensity = Float(-amount / 100)
        f.falloff = 0.6
        return (f.outputImage ?? input).cropped(to: extent)
    }

    // MARK: Geometry

    /// Size of the straightened frame that the normalized crop rect refers to.
    static func baseSize(for source: CGSize, geometry g: Geometry) -> CGSize {
        var size = source
        if g.quarterTurns % 2 != 0 { size = CGSize(width: size.height, height: size.width) }
        let s = straightenScale(size, degrees: g.straighten)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    private static func straightenScale(_ size: CGSize, degrees: Double) -> CGFloat {
        let a = abs(degrees) * .pi / 180
        guard a > 0 else { return 1 }
        let c = cos(a), s = sin(a), w = size.width, h = size.height
        return min(w / (w * c + h * s), h / (w * s + h * c)) * 0.999
    }

    static func applyGeometry(_ input: CIImage, _ g: Geometry, mode: GeometryMode) -> CIImage {
        var img = input.normalizedOrigin()

        if g.flipHorizontal {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).normalizedOrigin()
        }
        if g.flipVertical {
            img = img.transformed(by: CGAffineTransform(scaleX: 1, y: -1)).normalizedOrigin()
        }
        let turns = ((g.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            let size = img.extent.size
            img = img.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)).normalizedOrigin()
            let rotated = turns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
            img = img.cropped(to: CGRect(origin: .zero, size: rotated.rounded()))
        }

        if mode == .orientOnly { return img }

        img = applyPerspective(img, vertical: g.perspectiveVertical, horizontal: g.perspectiveHorizontal)

        if g.straighten != 0 {
            let e = img.extent
            let center = CGPoint(x: e.midX, y: e.midY)
            let radians = -g.straighten * .pi / 180
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            let s = straightenScale(e.size, degrees: g.straighten)
            let inner = CGRect(x: center.x - e.width * s / 2, y: center.y - e.height * s / 2,
                               width: e.width * s, height: e.height * s)
            img = img.transformed(by: transform).cropped(to: inner).normalizedOrigin()
        }

        if mode == .full, let crop = g.crop, crop != .full {
            let size = img.extent.size
            var rect = CGRect(x: (crop.x * size.width).rounded(),
                              y: ((1 - crop.y - crop.height) * size.height).rounded(),
                              width: max(1, (crop.width * size.width).rounded()),
                              height: max(1, (crop.height * size.height).rounded()))
            // Keep locked ratios exact in pixels (e.g. 1:1 → 2000×2000, not 2000×2001).
            if let landscape = g.aspect.landscapeRatio(original: size) {
                let ratio = g.aspectPortrait ? 1 / landscape : landscape
                rect.size.height = max(1, (rect.width / ratio).rounded())
                if rect.maxY > size.height { rect.origin.y = max(0, size.height - rect.height) }
            }
            img = img.cropped(to: rect).normalizedOrigin()
        }
        return img
    }

    /// Keystone correction that only ever stretches outward, so the original
    /// frame stays fully covered and we can crop back to it.
    private static func applyPerspective(_ input: CIImage, vertical: Double, horizontal: Double) -> CIImage {
        guard vertical != 0 || horizontal != 0 else { return input }
        let w = input.extent.width, h = input.extent.height
        var tl = CGPoint(x: 0, y: h), tr = CGPoint(x: w, y: h)
        var bl = CGPoint(x: 0, y: 0), br = CGPoint(x: w, y: 0)

        let kv = abs(vertical) / 100 * 0.4 * w / 2
        if vertical > 0 { tl.x -= kv; tr.x += kv } else if vertical < 0 { bl.x -= kv; br.x += kv }

        let kh = abs(horizontal) / 100 * 0.4 * h / 2
        if horizontal > 0 { tr.y += kh; br.y -= kh } else if horizontal < 0 { tl.y += kh; bl.y -= kh }

        let f = CIFilter.perspectiveTransform()
        f.inputImage = input
        f.topLeft = tl
        f.topRight = tr
        f.bottomLeft = bl
        f.bottomRight = br
        return (f.outputImage ?? input).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}

extension CIImage {
    func normalizedOrigin() -> CIImage {
        let e = extent
        guard e.minX != 0 || e.minY != 0 else { return self }
        return transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}

extension CGSize {
    func rounded() -> CGSize {
        CGSize(width: width.rounded(), height: height.rounded())
    }
}
