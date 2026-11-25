import Foundation

struct Preset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var look: Look
    var created = Date()
    var isBuiltIn = false

    enum CodingKeys: String, CodingKey { case id, name, look, created }
}

extension Preset {
    private static func make(_ name: String, _ adjustments: [String: Double], curve: [CurvePoint]? = nil) -> Preset {
        Preset(name: name,
                      look: Look(adjustments: adjustments, curves: curve.map { Curves(rgb: $0) }),
                      isBuiltIn: true)
    }

    private static func p(_ x: Double, _ y: Double) -> CurvePoint { CurvePoint(x: x, y: y) }
    private static func hsl(_ band: HSLBand, _ channel: HSLChannel) -> String { EditRecipe.hslKey(band, channel) }

    static let builtIn: [Preset] = [
        make("Vivid", ["contrast": 20, "vibrance": 35, "saturation": 8, "clarity": 15]),
        make("Punchy", ["contrast": 40, "blacks": -15, "whites": 15, "clarity": 25, "vibrance": 20]),
        make("Matte", ["contrast": -10, "saturation": -12],
             curve: [p(0, 0.09), p(0.25, 0.27), p(0.75, 0.76), p(1, 0.95)]),
        make("Warm Film", ["temperature": 25, "tint": 5, "contrast": 10, "saturation": -8, "vignette": -15],
             curve: [p(0, 0.05), p(0.5, 0.5), p(1, 0.97)]),
        make("Cool Fade", ["temperature": -20, "saturation": -15, "highlights": -10],
             curve: [p(0, 0.07), p(0.5, 0.52), p(1, 0.96)]),
        make("Golden Hour", ["temperature": 35, "tint": 8, "highlights": -15, "shadows": 15,
                             "vibrance": 20, "vignette": -20]),
        make("Teal & Orange", ["contrast": 15,
                               hsl(.orange, .hue): -5, hsl(.orange, .saturation): 20,
                               hsl(.aqua, .hue): 15, hsl(.aqua, .saturation): 15,
                               hsl(.blue, .hue): -20, hsl(.green, .hue): 30, hsl(.green, .saturation): -30]),
        make("Soft Portrait", ["clarity": -20, "highlights": -20, "shadows": 15, "vibrance": 10,
                               hsl(.orange, .luminance): 15, hsl(.orange, .saturation): -10]),
        make("B&W Classic", ["saturation": -100, "contrast": 15]),
        make("B&W High Contrast", ["saturation": -100, "contrast": 45, "blacks": -20, "whites": 20, "clarity": 20]),
        make("B&W Soft", ["saturation": -100, "contrast": -10, "clarity": -10],
             curve: [p(0, 0.08), p(0.5, 0.52), p(1, 0.96)]),
    ]
}

/// User presets live in `<root>/.syncdarkroom/presets/` so they sync with the photos.
enum PresetStore {
    static func directory(root: URL) -> URL {
        SidecarStore.directory(in: root).appendingPathComponent("presets", isDirectory: true)
    }

    static func load(root: URL) -> [Preset] {
        let dir = directory(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            return ImageLoading.coordinatedRead(url) { readURL in
                guard let data = try? Data(contentsOf: readURL) else { return nil }
                return try? decoder.decode(Preset.self, from: data)
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ preset: Preset, root: URL) throws {
        let dir = directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(preset)
        try coordinatedWrite(to: dir.appendingPathComponent(preset.id.uuidString + ".json")) { target in
            try data.write(to: target, options: .atomic)
        }
    }

    static func delete(_ preset: Preset, root: URL) throws {
        try coordinatedDelete(directory(root: root).appendingPathComponent(preset.id.uuidString + ".json"))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Copied edit settings (the look only, never the crop), kept across launches.
@MainActor
enum SettingsClipboard {
    private static let key = "copiedLook"

    static var look: Look? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Look.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
