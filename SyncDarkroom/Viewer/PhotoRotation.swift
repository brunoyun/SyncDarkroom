import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RotationError: LocalizedError {
    case raw
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .raw:
            "RAW files can't be rewritten. Open the photo in the editor and use Crop → Rotate; the rotation is saved in the edited copy."
        case .unsupported(let name):
            "\(name) is in a format that can't be rotated losslessly."
        case .failed(let name):
            "Rotating \(name) failed."
        }
    }
}

/// Rotates a photo 90° clockwise without re-compressing it (only the orientation tag changes).
enum PhotoRotation {
    static func rotateClockwise(_ url: URL) throws {
        if let sidecar = SidecarStore.load(forCopy: url) {
            // Edited copy: rotate the file, and remember it in the recipe so re-saving keeps it.
            try rotateFileOrientation(url)
            var updated = sidecar
            updated.recipe.outputTurns = ((updated.recipe.outputTurns ?? 0) + 1) % 4
            if updated.recipe.outputTurns == 0 { updated.recipe.outputTurns = nil }
            updated.updated = Date()
            try SidecarStore.save(updated, folder: url.deletingLastPathComponent())
            return
        }
        if RawDecoder.isRaw(url) { throw RotationError.raw }
        try rotateFileOrientation(url)
        compensateEditedCopies(ofOriginal: url)
    }

    // MARK: Orientation tag

    /// EXIF orientation after an extra 90° clockwise turn.
    static func rotatedClockwise(_ orientation: Int) -> Int {
        switch orientation {
        case 1: 6
        case 6: 3
        case 3: 8
        case 8: 1
        case 2: 7
        case 7: 4
        case 4: 5
        case 5: 2
        default: 6
        }
    }

    private static func rotateFileOrientation(_ url: URL) throws {
        let name = url.lastPathComponent
        let originalDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: temp) }

        let ok: Bool? = ImageLoading.coordinatedRead(url) { readURL in
            guard let source = CGImageSourceCreateWithURL(readURL as CFURL, nil),
                  let type = CGImageSourceGetType(source),
                  let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil)
            else { return false }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let current = props?[kCGImagePropertyOrientation] as? Int ?? 1
            let options: [CFString: Any] = [
                kCGImageDestinationMergeMetadata: true,
                kCGImageDestinationOrientation: rotatedClockwise(current),
            ]
            var error: Unmanaged<CFError>?
            return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
        }
        guard let ok else { throw RotationError.failed(name) }
        guard ok else { throw RotationError.unsupported(name) }

        try coordinatedWrite(to: url) { target in
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        }
        // Keep the photo's place in date order; nudge the time so thumbnail caches refresh.
        if let originalDate {
            try? FileManager.default.setAttributes([.modificationDate: originalDate.addingTimeInterval(0.001)],
                                                  ofItemAtPath: url.path)
        }
    }

    // MARK: Keep existing edits aligned

    /// The original's pixels are now shown rotated, so recipes made from it (which store masks
    /// and heal spots in the original's displayed frame) are adjusted to give the same result.
    private static func compensateEditedCopies(ofOriginal url: URL) {
        let folder = url.deletingLastPathComponent()
        for (copyName, sourceName) in SidecarStore.copySources(in: folder) where sourceName == url.lastPathComponent {
            let copy = folder.appendingPathComponent(copyName)
            guard var sidecar = SidecarStore.load(forCopy: copy) else { continue }
            sidecar.recipe = compensated(sidecar.recipe)
            try? SidecarStore.save(sidecar, folder: folder)
        }
    }

    /// Recipe that renders the same output after its source was rotated 90° clockwise.
    static func compensated(_ input: EditRecipe) -> EditRecipe {
        var r = input
        func turn(_ p: NPoint) -> NPoint { NPoint(x: 1 - p.y, y: p.x) }

        // Geometry applies flips, then quarter turns, to the source. Undoing the new source
        // rotation means one turn less — or one more when exactly one axis is flipped.
        let g = r.geometry
        let delta = g.flipHorizontal != g.flipVertical ? 1 : 3
        r.geometry.quarterTurns = (g.quarterTurns + delta) % 4

        r.heals = r.heals?.map { spot in
            var s = spot
            s.target = turn(s.target)
            s.source = turn(s.source)
            return s
        }
        r.masks = r.masks?.map { layer in
            var m = layer
            m.linearStart = turn(m.linearStart)
            m.linearEnd = turn(m.linearEnd)
            m.center = turn(m.center)
            swap(&m.radiusX, &m.radiusY)
            m.strokes = m.strokes.map { stroke in
                var st = stroke
                st.points = st.points.map { p in StrokePoint(x: 1 - p.y, y: p.x, p: p.p) }
                return st
            }
            return m
        }
        return r
    }
}
