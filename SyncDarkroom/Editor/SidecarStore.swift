import CoreImage
import Foundation
import ImageIO

/// The edit recipe behind one edited copy, stored at
/// `<folder>/.syncdarkroom/<copy name>.json`. One file per copy means an original can
/// have any number of independent edits, and two devices editing different copies
/// never write the same sidecar (no Syncthing conflicts).
struct Sidecar: Codable, Equatable, Sendable {
    var version = 2
    var app = "SyncDarkroom"
    /// File name of the original, in the same folder.
    var source: String
    /// File name of the edited copy this recipe produced.
    var output: String?
    var updated: Date
    var recipe: EditRecipe
}

enum SidecarStore {
    static let directoryName = ".syncdarkroom"

    static func directory(in folder: URL) -> URL {
        folder.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func url(forCopy copy: URL) -> URL {
        directory(in: copy.deletingLastPathComponent())
            .appendingPathComponent(copy.lastPathComponent + ".json")
    }

    /// The recipe that produced `copy`, if it was made by SyncDarkroom.
    static func load(forCopy copy: URL) -> Sidecar? {
        let direct = url(forCopy: copy)
        // Version-1 sidecars were named after the original, so a file with this name may
        // describe a different copy; only accept it if it really produced `copy`.
        if FileManager.default.fileExists(atPath: direct.path), let sidecar = read(direct),
           sidecar.output == copy.lastPathComponent {
            return sidecar
        }
        // Version-1 sidecars were named after the original; find one pointing at this copy.
        return all(in: copy.deletingLastPathComponent())
            .first { $0.sidecar.output == copy.lastPathComponent }?.sidecar
    }

    static func save(_ sidecar: Sidecar, folder: URL) throws {
        guard let output = sidecar.output else { return }
        let dir = directory(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(sidecar)
        try coordinatedWrite(to: dir.appendingPathComponent(output + ".json")) { target in
            try data.write(to: target, options: .atomic)
        }
        // Retire a version-1 sidecar that described this same copy.
        let legacy = dir.appendingPathComponent(sidecar.source + ".json")
        if legacy.lastPathComponent != output + ".json", read(legacy)?.output == output {
            try? coordinatedDelete(legacy)
        }
    }

    static func remove(forCopy copy: URL) {
        let url = url(forCopy: copy)
        if FileManager.default.fileExists(atPath: url.path) { try? coordinatedDelete(url) }
    }

    /// Names of originals in `folder` that have at least one edited copy.
    static func editedSourceNames(in folder: URL) -> Set<String> {
        Set(all(in: folder).map(\.sidecar.source))
    }

    /// Edited-copy file name → original file name, for every SyncDarkroom copy in `folder`.
    static func copySources(in folder: URL) -> [String: String] {
        var map: [String: String] = [:]
        for entry in all(in: folder) {
            if let output = entry.sidecar.output { map[output] = entry.sidecar.source }
        }
        return map
    }

    private static func all(in folder: URL) -> [(url: URL, sidecar: Sidecar)] {
        let dir = directory(in: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            return read(url).map { (url, $0) }
        }
    }

    private static func read(_ url: URL) -> Sidecar? {
        ImageLoading.coordinatedRead(url) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return nil }
            return try? decoder.decode(Sidecar.self, from: data)
        }
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

func coordinatedWrite(to url: URL, _ body: (URL) throws -> Void) throws {
    var coordinationError: NSError?
    var bodyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
        do { try body(target) } catch { bodyError = error }
    }
    if let error = coordinationError ?? bodyError { throw error }
}

func coordinatedDelete(_ url: URL) throws {
    var coordinationError: NSError?
    var bodyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
        do { try FileManager.default.removeItem(at: target) } catch { bodyError = error }
    }
    if let error = coordinationError ?? bodyError { throw error }
}

enum ExportError: LocalizedError {
    case unreadable(String)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name)."
        case .renderFailed: "Rendering the edited photo failed."
        }
    }
}

/// Renders the full-resolution edit and writes it as an edited copy next to the original.
struct ExportJob: Sendable {
    let source: URL
    let recipe: EditRecipe
    let format: ExportFormat
    let quality: Double
    /// The edited copy to update, or nil to create a new copy (never overwriting another one).
    let updating: URL?

    func run() throws -> Sidecar {
        let output = outputURL()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)
        defer { try? FileManager.default.removeItem(at: temp) }

        try renderFile(to: temp)
        return try finish(rendered: temp, output: output)
    }

    /// Renders the full-resolution result into `temp`.
    func renderFile(to temp: URL) throws {
        var renderError: Error?
        let rendered: Bool? = ImageLoading.coordinatedRead(source) { readURL in
            do {
                try render(from: readURL, to: temp)
                return true
            } catch {
                renderError = error
                return false
            }
        }
        if let renderError { throw renderError }
        guard rendered == true else { throw ExportError.unreadable(source.lastPathComponent) }
    }

    private func finish(rendered temp: URL, output: URL) throws -> Sidecar {
        try coordinatedWrite(to: output) { target in
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: temp, to: target)
        }

        // Date the copy like its original so it sorts next to it (here and on synced devices).
        if let date = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: output.path)
        }

        let folder = source.deletingLastPathComponent()
        let sidecar = Sidecar(source: source.lastPathComponent, output: output.lastPathComponent,
                              updated: Date(), recipe: recipe)
        try SidecarStore.save(sidecar, folder: folder)

        // Same edit saved in a different format: the new file replaces the old one.
        if let updating, updating != output {
            SidecarStore.remove(forCopy: updating)
            if FileManager.default.fileExists(atPath: updating.path) { try? coordinatedDelete(updating) }
        }
        return sidecar
    }

    private func render(from url: URL, to temp: URL) throws {
        let isRaw = RawDecoder.isRaw(url)
        let decoded = isRaw
            ? RawDecoder.fullImage(url: url, settings: recipe.raw)
            : CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        guard let input = decoded else {
            throw ExportError.unreadable(url.lastPathComponent)
        }
        let output = Renderer.render(input, recipe: recipe, scale: 1)
        let metadata = Self.metadata(from: url, size: output.extent.size)
        let image = output.settingProperties(metadata)

        let colorSpace: CGColorSpace = {
            // RAW has no output color space of its own; keep its wide gamut.
            if isRaw { return CGColorSpace(name: CGColorSpace.displayP3)! }
            if let cs = input.colorSpace, cs.model == .rgb { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        switch format {
        case .jpeg:
            try Renderer.context.writeJPEGRepresentation(of: image, to: temp, colorSpace: colorSpace, options: options)
        case .heic:
            try Renderer.context.writeHEIFRepresentation(of: image, to: temp, format: .RGBA8, colorSpace: colorSpace, options: options)
        }
    }

    /// Original EXIF/TIFF/GPS metadata with orientation reset (pixels are already upright).
    private static func metadata(from url: URL, size: CGSize) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return [:] }
        props[kCGImagePropertyOrientation as String] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        props.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        props.removeValue(forKey: kCGImagePropertyProfileName as String)
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFSoftware as String] = "SyncDarkroom"
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = Int(size.width)
            exif[kCGImagePropertyExifPixelYDimension as String] = Int(size.height)
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        // RAW-specific dictionaries don't apply to the rendered copy.
        props.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        props.removeValue(forKey: kCGImagePropertyRawDictionary as String)
        return props
    }

    private func outputURL() -> URL {
        let folder = source.deletingLastPathComponent()
        let ext = format.fileExtension
        if let updating {
            // Keep the copy's name; only the extension follows the chosen format.
            return updating.deletingPathExtension().appendingPathExtension(ext)
        }
        // New copy: first free name, never an existing file (other edits are kept).
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base)_edit.\(ext)")
        var n = 2
        while Self.isTaken(candidate) {
            candidate = folder.appendingPathComponent("\(base)-\(n)_edit.\(ext)")
            n += 1
        }
        return candidate
    }

    /// A name is taken if the file exists or another device's sidecar already claims it
    /// (its copy may not have finished syncing here yet).
    private static func isTaken(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: SidecarStore.url(forCopy: url).path)
    }
}

/// "Replace Original": the edit becomes the photo. Writes the rendered result under the
/// original's name, deletes the original (and the edited copy being worked on), and drops
/// recipes that pointed at the original, since its pixels are now the edited ones.
struct ReplaceOriginalJob: Sendable {
    let source: URL
    let recipe: EditRecipe
    let format: ExportFormat
    let quality: Double
    /// The edited copy that was open in the editor, deleted afterwards.
    let editingCopy: URL?

    /// Returns the URL of the photo that replaced the original.
    func run() throws -> URL {
        let fm = FileManager.default
        let folder = source.deletingLastPathComponent()
        let originalDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)
        defer { try? fm.removeItem(at: temp) }

        try ExportJob(source: source, recipe: recipe, format: format, quality: quality, updating: nil)
            .renderFile(to: temp)

        // Same name when the format matches (e.g. IMG_1.JPG stays IMG_1.JPG), else the new extension.
        let sameFormat = ExportFormat.allCases.first {
            $0.fileExtension == source.pathExtension.lowercased()
                || ($0 == .jpeg && source.pathExtension.lowercased() == "jpeg")
        } == format
        var target = sameFormat ? source : source.deletingPathExtension().appendingPathExtension(format.fileExtension)
        if target != source {
            var n = 2
            let base = source.deletingPathExtension().lastPathComponent
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(base)-\(n).\(format.fileExtension)")
                n += 1
            }
        }

        try coordinatedWrite(to: target) { destination in
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: temp, to: destination)
        }
        if let originalDate {
            try? fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: target.path)
        }
        if target != source { try coordinatedDelete(source) }

        // Recipes of this original no longer apply: drop them (their copies stay as plain files).
        for (copyName, sourceName) in SidecarStore.copySources(in: folder) where sourceName == source.lastPathComponent {
            SidecarStore.remove(forCopy: folder.appendingPathComponent(copyName))
        }
        if let editingCopy, editingCopy != target, fm.fileExists(atPath: editingCopy.path) {
            try? coordinatedDelete(editingCopy)
        }
        return target
    }
}
