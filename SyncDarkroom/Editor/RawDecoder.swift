import CoreImage
import Foundation

/// Decoder-level RAW controls (applied while demosaicing, before every other adjustment).
enum RawControl: String, CaseIterable, Identifiable, Sendable {
    case temperature, tint
    case boost, shadowBoost, localToneMap
    case luminanceNoise, colorNoise, sharpness, detail, moire

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .boost: "Tone Boost"
        case .shadowBoost: "Shadow Boost"
        case .localToneMap: "Local Tone Mapping"
        case .luminanceNoise: "Luminance Noise"
        case .colorNoise: "Color Noise"
        case .sharpness: "Sharpness"
        case .detail: "Detail"
        case .moire: "Moiré Reduction"
        }
    }

    enum Section { case whiteBalance, tone, detail }

    var section: Section {
        switch self {
        case .temperature, .tint: .whiteBalance
        case .boost, .shadowBoost, .localToneMap: .tone
        case .luminanceNoise, .colorNoise, .sharpness, .detail, .moire: .detail
        }
    }

    func range(default value: Double) -> ClosedRange<Double> {
        switch self {
        case .temperature: 2000...15000
        case .tint: -150...150
        case .shadowBoost: 0...2
        case .detail: 0...max(1, value * 2)
        default: 0...1
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .temperature: "\(Int(value.rounded())) K"
        case .tint: (value > 0.5 ? "+" : "") + "\(Int(value.rounded()))"
        default: "\(Int((value * 100).rounded()))"
        }
    }
}

/// Overrides of the camera's default RAW settings. Missing values mean "camera default"
/// (for white balance: "as shot").
struct RawSettings: Codable, Equatable, Sendable {
    var values: [String: Double] = [:]
    var lensCorrection: Bool?
    var highlightRecovery: Bool?

    var isEmpty: Bool { values.isEmpty && lensCorrection == nil && highlightRecovery == nil }

    subscript(_ control: RawControl) -> Double? {
        get { values[control.rawValue] }
        set { values[control.rawValue] = newValue }
    }
}

/// What the decoder does for this file when nothing is overridden, and which controls it supports.
struct RawDefaults: Sendable, Equatable {
    var values: [String: Double] = [:]
    var supported: Set<String> = []
    var lensCorrection = false
    var lensCorrectionSupported = false
    var highlightRecovery = false
    var highlightRecoverySupported = false

    func value(_ control: RawControl) -> Double { values[control.rawValue] ?? 0 }
    func supports(_ control: RawControl) -> Bool { supported.contains(control.rawValue) }
}

enum RawDecoder {
    static func isRaw(_ url: URL) -> Bool {
        ImageType(fileExtension: url.pathExtension) == .raw
    }

    static func defaults(of f: CIRAWFilter) -> RawDefaults {
        var d = RawDefaults()
        func add(_ c: RawControl, _ value: Float, _ supported: Bool = true) {
            d.values[c.rawValue] = Double(value)
            if supported { d.supported.insert(c.rawValue) }
        }
        add(.temperature, f.neutralTemperature)
        add(.tint, f.neutralTint)
        add(.boost, f.boostAmount)
        add(.shadowBoost, f.boostShadowAmount)
        add(.localToneMap, f.localToneMapAmount, f.isLocalToneMapSupported)
        add(.luminanceNoise, f.luminanceNoiseReductionAmount, f.isLuminanceNoiseReductionSupported)
        add(.colorNoise, f.colorNoiseReductionAmount, f.isColorNoiseReductionSupported)
        add(.sharpness, f.sharpnessAmount, f.isSharpnessSupported)
        add(.detail, f.detailAmount, f.isDetailSupported)
        add(.moire, f.moireReductionAmount, f.isMoireReductionSupported)
        d.lensCorrectionSupported = f.isLensCorrectionSupported
        d.lensCorrection = f.isLensCorrectionEnabled
        if #available(iOS 26.0, *) {
            d.highlightRecoverySupported = f.isHighlightRecoverySupported
            d.highlightRecovery = f.isHighlightRecoveryEnabled
        }
        return d
    }

    static func apply(_ s: RawSettings?, to f: CIRAWFilter, defaults d: RawDefaults) {
        let s = s ?? RawSettings()
        func v(_ c: RawControl) -> Float { Float(s[c] ?? d.value(c)) }
        // White balance: only override when the user changed it, so "as shot" stays exact.
        if s[.temperature] != nil || s[.tint] != nil {
            f.neutralTemperature = v(.temperature)
            f.neutralTint = v(.tint)
        }
        f.boostAmount = v(.boost)
        f.boostShadowAmount = v(.shadowBoost)
        if d.supports(.localToneMap) { f.localToneMapAmount = v(.localToneMap) }
        if d.supports(.luminanceNoise) { f.luminanceNoiseReductionAmount = v(.luminanceNoise) }
        if d.supports(.colorNoise) { f.colorNoiseReductionAmount = v(.colorNoise) }
        if d.supports(.sharpness) { f.sharpnessAmount = v(.sharpness) }
        if d.supports(.detail) { f.detailAmount = v(.detail) }
        if d.supports(.moire) { f.moireReductionAmount = v(.moire) }
        if d.lensCorrectionSupported { f.isLensCorrectionEnabled = s.lensCorrection ?? d.lensCorrection }
        if #available(iOS 26.0, *), d.highlightRecoverySupported {
            f.isHighlightRecoveryEnabled = s.highlightRecovery ?? d.highlightRecovery
        }
    }

    /// Full-resolution decode graph for export.
    static func fullImage(url: URL, settings: RawSettings?) -> CIImage? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        apply(settings, to: f, defaults: defaults(of: f))
        f.scaleFactor = 1
        return f.outputImage
    }

    struct Preview: @unchecked Sendable {
        /// Decoded once into a half-float bitmap so the other sliders don't re-demosaic.
        let image: CIImage
        /// Full-resolution size after orientation.
        let fullSize: CGSize
        let defaults: RawDefaults
    }

    /// Decodes a downscaled preview, keeping highlights above 1.0 for recovery.
    static func preview(url: URL, settings: RawSettings?, maxPixelSize: CGFloat = 2048) -> Preview? {
        ImageLoading.coordinatedRead(url) { readURL in
            guard let f = CIRAWFilter(imageURL: readURL) else { return nil }
            let d = defaults(of: f)
            apply(settings, to: f, defaults: d)
            f.scaleFactor = 1
            guard let full = f.outputImage?.extent.size, full.width > 0 else { return nil }
            let scale = min(1, maxPixelSize / max(full.width, full.height))
            f.scaleFactor = Float(scale)
            guard let output = f.outputImage,
                  let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                  let cg = Renderer.context.createCGImage(output, from: output.extent, format: .RGBAh, colorSpace: linear)
            else { return nil }
            return Preview(image: CIImage(cgImage: cg), fullSize: full, defaults: d)
        }
    }
}
