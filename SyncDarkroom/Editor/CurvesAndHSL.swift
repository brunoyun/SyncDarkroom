import CoreGraphics
import Foundation

// MARK: - Tone curves

struct CurvePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// A point curve on 0…1 (sRGB-gamma values), interpolated with a monotone cubic
/// spline so it never overshoots between points.
struct ToneCurve: Codable, Equatable, Sendable {
    var points: [CurvePoint] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    static let maxPoints = 14

    var isIdentity: Bool {
        points.allSatisfy { abs($0.x - $0.y) < 0.0005 }
    }

    /// Evaluates the curve at many x positions at once.
    func sample(count: Int) -> [Double] {
        let pts = points.sorted { $0.x < $1.x }.reduce(into: [CurvePoint]()) { result, p in
            if let last = result.last, p.x - last.x < 1e-4 { result[result.count - 1] = p } else { result.append(p) }
        }
        guard pts.count >= 2 else {
            let y = pts.first?.y ?? 0
            return Array(repeating: y, count: count)
        }
        let n = pts.count
        let xs = pts.map(\.x), ys = pts.map(\.y)
        var d = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) { d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k]) }

        // Fritsch–Carlson monotone tangents.
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for k in 1..<(n - 1) { m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2 }
        }
        for k in 0..<(n - 1) {
            if d[k] == 0 { m[k] = 0; m[k + 1] = 0; continue }
            let a = m[k] / d[k], b = m[k + 1] / d[k]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[k] = t * a * d[k]
                m[k + 1] = t * b * d[k]
            }
        }

        var out = [Double](repeating: 0, count: count)
        var seg = 0
        for i in 0..<count {
            let x = Double(i) / Double(max(1, count - 1))
            let y: Double
            if x <= xs[0] {
                y = ys[0]
            } else if x >= xs[n - 1] {
                y = ys[n - 1]
            } else {
                while seg < n - 2 && x > xs[seg + 1] { seg += 1 }
                let h = xs[seg + 1] - xs[seg]
                let t = (x - xs[seg]) / h
                let t2 = t * t, t3 = t2 * t
                y = (2 * t3 - 3 * t2 + 1) * ys[seg] + (t3 - 2 * t2 + t) * h * m[seg]
                    + (-2 * t3 + 3 * t2) * ys[seg + 1] + (t3 - t2) * h * m[seg + 1]
            }
            out[i] = min(1, max(0, y))
        }
        return out
    }
}

struct Curves: Codable, Equatable, Sendable {
    enum Channel: String, CaseIterable, Identifiable, Sendable {
        case rgb, red, green, blue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rgb: "RGB"
            case .red: "Red"
            case .green: "Green"
            case .blue: "Blue"
            }
        }
    }

    var rgb = ToneCurve()
    var red = ToneCurve()
    var green = ToneCurve()
    var blue = ToneCurve()

    init() {}

    init(rgb: [CurvePoint]) {
        self.rgb = ToneCurve(points: rgb)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try c.decodeIfPresent(ToneCurve.self, forKey: .rgb) ?? ToneCurve()
        red = try c.decodeIfPresent(ToneCurve.self, forKey: .red) ?? ToneCurve()
        green = try c.decodeIfPresent(ToneCurve.self, forKey: .green) ?? ToneCurve()
        blue = try c.decodeIfPresent(ToneCurve.self, forKey: .blue) ?? ToneCurve()
    }

    subscript(_ channel: Channel) -> ToneCurve {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    var isIdentity: Bool {
        rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    /// Float32 RGB triplets for CIColorCurves: each channel curve, then the RGB curve.
    func lutData(count: Int = 512) -> Data {
        let master = rgb.sample(count: count)
        let r = red.sample(count: count), g = green.sample(count: count), b = blue.sample(count: count)
        func apply(_ v: Double) -> Float {
            let pos = v * Double(count - 1)
            let i = Int(pos), f = pos - Double(i)
            let lo = master[min(i, count - 1)], hi = master[min(i + 1, count - 1)]
            return Float(lo + (hi - lo) * f)
        }
        var values = [Float]()
        values.reserveCapacity(count * 3)
        for i in 0..<count {
            values.append(apply(r[i]))
            values.append(apply(g[i]))
            values.append(apply(b[i]))
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - HSL

enum HSLBand: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Hue center in degrees.
    var hue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 310
        }
    }
}

enum HSLChannel: String, CaseIterable, Identifiable, Sendable {
    case hue, saturation, luminance
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

extension EditRecipe {
    static func hslKey(_ band: HSLBand, _ channel: HSLChannel) -> String {
        "hsl.\(band.rawValue).\(channel.rawValue)"
    }

    subscript(_ band: HSLBand, _ channel: HSLChannel) -> Double {
        get { adjustments[Self.hslKey(band, channel)] ?? 0 }
        set { adjustments[Self.hslKey(band, channel)] = abs(newValue) < 0.0001 ? nil : newValue }
    }

    /// 24 values ordered band-major (hue, sat, lum per band), or nil if all zero.
    var hslValues: [Float]? {
        var values = [Float]()
        var any = false
        for band in HSLBand.allCases {
            for channel in HSLChannel.allCases {
                let v = self[band, channel]
                if v != 0 { any = true }
                values.append(Float(v))
            }
        }
        return any ? values : nil
    }

    var curvesAreIdentity: Bool { curves?.isIdentity ?? true }
}

/// Builds a 3D color cube that applies per-hue-band hue/saturation/luminance shifts.
enum HSLCube {
    static let size = 32

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var key: [Float] = []
        var data = Data()
    }
    private static let cache = Cache()

    static func data(for values: [Float]) -> Data {
        cache.lock.lock()
        if cache.key == values {
            let data = cache.data
            cache.lock.unlock()
            return data
        }
        cache.lock.unlock()
        let data = compute(values)
        cache.lock.lock()
        cache.key = values
        cache.data = data
        cache.lock.unlock()
        return data
    }

    private static func compute(_ values: [Float]) -> Data {
        let n = size
        let centers = HSLBand.allCases.map { Float($0.hue) }
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rgb = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(n - 1)
                    let out = adjust(rgb, values: values, centers: centers)
                    let i = ((b * n + g) * n + r) * 4
                    cube[i] = out.x
                    cube[i + 1] = out.y
                    cube[i + 2] = out.z
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func adjust(_ c: SIMD3<Float>, values: [Float], centers: [Float]) -> SIMD3<Float> {
        let maxC = max(c.x, c.y, c.z), minC = min(c.x, c.y, c.z)
        let chroma = maxC - minC
        guard chroma > 0.0001 else { return c } // neutral: no hue to adjust
        var (h, s, l) = rgbToHSL(c)

        // Blend the two neighbouring bands' settings.
        let count = centers.count
        var k = count - 1
        for i in 0..<count where h >= centers[i] { k = i }
        let next = (k + 1) % count
        let start = centers[k]
        let end = next == 0 ? 360 : centers[next]
        var t = (h - start) / max(1, end - start)
        t = t * t * (3 - 2 * t)
        func value(_ channel: Int) -> Float {
            values[k * 3 + channel] * (1 - t) + values[next * 3 + channel] * t
        }
        let dHue = value(0) / 100, dSat = value(1) / 100, dLum = value(2) / 100

        // Fade the effect out for near-neutral colors so grays stay gray.
        let w = min(1, chroma / 0.15)

        h = (h + dHue * 30 * w).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        s = min(1, max(0, s * (1 + dSat * w)))
        let lumAmount = dLum * 0.6 * w
        l = lumAmount >= 0 ? l + (1 - l) * lumAmount : l * (1 + lumAmount)
        return hslToRGB(h, s, min(1, max(0, l)))
    }

    private static func rgbToHSL(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let maxC = max(c.x, c.y, c.z), minC = min(c.x, c.y, c.z)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        let s = d / (1 - abs(2 * l - 1) + 1e-6)
        var h: Float
        if maxC == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, min(1, s), l)
    }

    private static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> SIMD3<Float> {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let rgb: SIMD3<Float>
        switch hp {
        case ..<1: rgb = [c, x, 0]
        case ..<2: rgb = [x, c, 0]
        case ..<3: rgb = [0, c, x]
        case ..<4: rgb = [0, x, c]
        case ..<5: rgb = [x, 0, c]
        default: rgb = [c, 0, x]
        }
        let m = l - c / 2
        return rgb + SIMD3(repeating: m)
    }
}
