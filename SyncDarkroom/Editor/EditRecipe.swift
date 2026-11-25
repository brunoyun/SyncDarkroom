import Foundation

/// Slider-style adjustments. Stored by raw value so older/newer app versions
/// can read each other's sidecars (unknown keys are kept, missing ones are 0).
enum Adjustment: String, CaseIterable, Identifiable, Sendable {
    // Light
    case exposure, contrast, highlights, shadows, whites, blacks
    // Color
    case temperature, tint, vibrance, saturation
    // Detail & effects
    case clarity, sharpness, noiseReduction, vignette

    var id: String { rawValue }

    enum Group: String, CaseIterable, Sendable {
        case light, color, detail
    }

    var group: Group {
        switch self {
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: .light
        case .temperature, .tint, .vibrance, .saturation: .color
        case .clarity, .sharpness, .noiseReduction, .vignette: .detail
        }
    }

    var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .whites: "Whites"
        case .blacks: "Blacks"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .vibrance: "Vibrance"
        case .saturation: "Saturation"
        case .clarity: "Clarity"
        case .sharpness: "Sharpening"
        case .noiseReduction: "Noise Reduction"
        case .vignette: "Vignette"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -4...4
        case .sharpness, .noiseReduction: 0...100
        default: -100...100
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .exposure:
            let text = value.formatted(.number.precision(.fractionLength(2)))
            return (value > 0.004 ? "+" : "") + text + " EV"
        default:
            let rounded = Int(value.rounded())
            return rounded > 0 && range.lowerBound < 0 ? "+\(rounded)" : "\(rounded)"
        }
    }
}

struct CropRect: Codable, Equatable, Sendable {
    /// Normalized to the straightened frame, origin at top-left.
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
}

enum CropAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case free, original, square, r4x5, r5x7, r3x2, r16x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "Square"
        case .r4x5: "4:5"
        case .r5x7: "5:7"
        case .r3x2: "3:2"
        case .r16x9: "16:9"
        }
    }

    /// Landscape-oriented ratio (width / height ≥ 1), nil for free.
    func landscapeRatio(original: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original:
            max(original.width, original.height) / max(1, min(original.width, original.height))
        case .square: 1
        case .r4x5: 5.0 / 4.0
        case .r5x7: 7.0 / 5.0
        case .r3x2: 3.0 / 2.0
        case .r16x9: 16.0 / 9.0
        }
    }
}

struct Geometry: Codable, Equatable, Sendable {
    /// Clockwise quarter turns, 0...3.
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    /// Degrees, positive = clockwise.
    var straighten = 0.0
    /// −100...100. Positive vertical widens the top (fixes buildings leaning in).
    var perspectiveVertical = 0.0
    /// −100...100. Positive horizontal enlarges the right side.
    var perspectiveHorizontal = 0.0
    var crop: CropRect?
    var aspect: CropAspect = .free
    var aspectPortrait = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        perspectiveVertical = try c.decodeIfPresent(Double.self, forKey: .perspectiveVertical) ?? 0
        perspectiveHorizontal = try c.decodeIfPresent(Double.self, forKey: .perspectiveHorizontal) ?? 0
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
        aspect = (try? c.decodeIfPresent(CropAspect.self, forKey: .aspect)) ?? .free
        aspectPortrait = try c.decodeIfPresent(Bool.self, forKey: .aspectPortrait) ?? false
    }

    var isIdentity: Bool {
        quarterTurns % 4 == 0 && !flipHorizontal && !flipVertical && straighten == 0
            && perspectiveVertical == 0 && perspectiveHorizontal == 0
            && (crop == nil || crop == .full)
    }
}

/// Everything about an edit except crop & geometry: what presets and copy/paste carry.
struct Look: Codable, Equatable, Sendable {
    /// Slider values (including `hsl.<band>.<channel>` keys); missing = 0.
    var adjustments: [String: Double] = [:]
    var curves: Curves?

    init(adjustments: [String: Double] = [:], curves: Curves? = nil) {
        self.adjustments = adjustments.filter { $0.value != 0 }
        self.curves = (curves?.isIdentity ?? true) ? nil : curves
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try c.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        curves = try c.decodeIfPresent(Curves.self, forKey: .curves)
    }

    var isEmpty: Bool { adjustments.isEmpty && curves == nil }
}

struct EditRecipe: Codable, Equatable, Sendable {
    var adjustments: [String: Double] = [:]
    var curves: Curves?
    /// RAW decoder overrides; only meaningful for RAW originals.
    var raw: RawSettings?
    /// Local edits; stored in the original photo's frame.
    var heals: [HealSpot]?
    var masks: [MaskLayer]?
    /// Annotations on the final framed picture.
    var markup: Markup?
    var geometry = Geometry()
    /// Clockwise quarter turns applied to the finished picture (the viewer's rotate button).
    var outputTurns: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try c.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        curves = try c.decodeIfPresent(Curves.self, forKey: .curves)
        raw = try c.decodeIfPresent(RawSettings.self, forKey: .raw)
        heals = try c.decodeIfPresent([HealSpot].self, forKey: .heals)
        masks = try c.decodeIfPresent([MaskLayer].self, forKey: .masks)
        markup = try c.decodeIfPresent(Markup.self, forKey: .markup)
        outputTurns = try c.decodeIfPresent(Int.self, forKey: .outputTurns)
        geometry = try c.decodeIfPresent(Geometry.self, forKey: .geometry) ?? Geometry()
    }

    var look: Look {
        get { Look(adjustments: adjustments, curves: curves) }
        set {
            adjustments = newValue.adjustments
            curves = newValue.curves
        }
    }

    /// The same crop/geometry without any tone or color changes: the "before" view.
    var geometryOnly: EditRecipe {
        var r = EditRecipe()
        r.geometry = geometry
        r.outputTurns = outputTurns
        return r
    }

    subscript(_ adjustment: Adjustment) -> Double {
        get { adjustments[adjustment.rawValue] ?? 0 }
        set { adjustments[adjustment.rawValue] = abs(newValue) < 0.0001 ? nil : newValue }
    }

    var isIdentity: Bool {
        adjustments.values.allSatisfy { $0 == 0 } && curvesAreIdentity && (raw?.isEmpty ?? true) && (heals?.isEmpty ?? true) && (masks?.isEmpty ?? true)
            && (markup?.isEmpty ?? true) && geometry.isIdentity
    }
}

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, heic

    var id: String { rawValue }
    var title: String { self == .jpeg ? "JPEG" : "HEIC" }
    var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
}
