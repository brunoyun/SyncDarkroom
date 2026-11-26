import CoreGraphics
import CoreImage
import Foundation
import Vision

/// One face found in a photo.
struct FaceRecord: Codable, Sendable, Hashable {
    /// Normalized box in the upright photo, origin top-left.
    var box: CGRect
    /// Head tilt in radians (Vision's roll), to show the face upright.
    var roll: Double?
    /// SFace identity embedding of the aligned face (128 Float32 values, unit length; empty if unavailable).
    var embedding: Data
}

/// Everything the on-device analysis learned about one photo. Cached per photo, keyed by size and date.
struct PhotoFeatures: Codable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var size: Int64
    var modified: Date
    /// Variance of the Laplacian on a 512 px grayscale copy: low = blurry.
    var sharpness: Double
    /// 64-bit difference hash: near-duplicates differ in few bits.
    var dHash: UInt64
    /// Vision object/scene labels → confidence.
    var labels: [String: Float]
    /// Vision scene feature print (Float32 values) for near-duplicate detection.
    var scenePrint: Data?
    var faces: [FaceRecord]
    /// Vision ran (it can't in the simulator); otherwise labels, prints and faces are empty.
    var visionOK: Bool
    /// MobileCLIP image embedding (Float32 values, unit length).
    var clip: Data?
    /// SHA-256 of the file, computed when needed for exact-duplicate checks.
    var sha256: String?
}

extension Data {
    var floats: [Float] {
        withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    init(floats: [Float]) {
        self = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

enum VectorMath {
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }
}

enum FeatureExtractor {
    /// Analyzes an upright thumbnail (about 1024 px on the long side).
    static func extract(_ image: CGImage, size: Int64, modified: Date,
                        clip: CLIPEncoder?, faceEncoder: FaceEncoder?) -> PhotoFeatures {
        let gray = grayscale(image, maxSide: 512)
        var features = PhotoFeatures(size: size, modified: modified,
                                     sharpness: laplacianVariance(gray.pixels, width: gray.width, height: gray.height),
                                     dHash: differenceHash(image), labels: [:], scenePrint: nil, faces: [],
                                     visionOK: false, clip: nil, sha256: nil)

        let classify = VNClassifyImageRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        let faces = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classify])
        try? handler.perform([print])
        try? handler.perform([faces])
        if let results = classify.results {
            features.visionOK = true
            for observation in results where observation.confidence > 0.05 {
                features.labels[observation.identifier] = observation.confidence
            }
        }
        if let p = print.results?.first { features.scenePrint = p.data }
        for face in faces.results ?? [] {
            guard let record = faceRecord(face, in: image, encoder: faceEncoder) else { continue }
            features.faces.append(record)
        }
        if let clip, let embedding = clip.embed(image: image) {
            features.clip = Data(floats: embedding)
        }
        return features
    }

    // MARK: Faces

    /// Smallest face (in thumbnail pixels) worth recognizing.
    static let minimumFaceSide: CGFloat = 32

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func faceRecord(_ face: VNFaceObservation, in image: CGImage, encoder: FaceEncoder?) -> FaceRecord? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let b = face.boundingBox
        guard b.width * w >= minimumFaceSide, b.height * h >= minimumFaceSide else { return nil }
        let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        let roll = face.roll?.doubleValue
        guard let encoder, let aligned = alignedFace(face, in: image),
              let embedding = encoder.embed(aligned) else {
            return FaceRecord(box: box, roll: roll, embedding: Data())
        }
        return FaceRecord(box: box, roll: roll, embedding: Data(floats: embedding))
    }

    /// ArcFace's 112×112 reference positions (top-left origin) of the eyes, nose tip and mouth
    /// corners, in image order (left eye in the picture first).
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// The five landmarks in image pixels (bottom-left origin), in template order.
    static func fivePoints(_ face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let lm = face.landmarks else { return nil }
        func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let pts = region?.pointsInImage(imageSize: imageSize), !pts.isEmpty else { return nil }
            return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        }
        // Vision names eyes as seen in the picture: its "left eye" is on the left of an upright face.
        guard let eyeA = center(lm.leftPupil) ?? center(lm.leftEye),
              let eyeB = center(lm.rightPupil) ?? center(lm.rightEye),
              let nose = center(lm.nose),
              let lips = lm.outerLips?.pointsInImage(imageSize: imageSize), lips.count >= 4 else { return nil }
        // Mouth corners: the lip points furthest along the eye line, in each direction.
        let axis = CGPoint(x: eyeB.x - eyeA.x, y: eyeB.y - eyeA.y)
        func along(_ p: CGPoint) -> CGFloat { p.x * axis.x + p.y * axis.y }
        guard let mouthA = lips.min(by: { along($0) < along($1) }),
              let mouthB = lips.max(by: { along($0) < along($1) }) else { return nil }
        return [eyeA, eyeB, nose, mouthA, mouthB]
    }

    /// Face warped onto the ArcFace template (112×112), or a plain upright crop without landmarks.
    static func alignedFace(_ face: VNFaceObservation, in image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let side: CGFloat = 112
        let transform: CGAffineTransform
        if let src = fivePoints(face, imageSize: size) {
            // Template in Core Image's bottom-left coordinates.
            let dst = template.map { CGPoint(x: $0.x, y: side - $0.y) }
            guard let t = similarity(from: src, to: dst) else { return nil }
            transform = t
        } else {
            let b = face.boundingBox
            let center = CGPoint(x: b.midX * size.width, y: b.midY * size.height)
            let extent = max(b.width * size.width, b.height * size.height) * 1.1
            let roll = CGFloat(face.roll?.doubleValue ?? 0)
            transform = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: -roll))
                .concatenating(CGAffineTransform(scaleX: side / extent, y: side / extent))
                .concatenating(CGAffineTransform(translationX: side / 2, y: side / 2))
        }
        let output = CIImage(cgImage: image).clampedToExtent().transformed(by: transform)
        return ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// Least-squares similarity transform (rotation, uniform scale, translation) mapping src onto dst.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        let n = CGFloat(src.count)
        let sx = src.map(\.x).reduce(0, +) / n, sy = src.map(\.y).reduce(0, +) / n
        let dx = dst.map(\.x).reduce(0, +) / n, dy = dst.map(\.y).reduce(0, +) / n
        var num1: CGFloat = 0, num2: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let px = s.x - sx, py = s.y - sy, qx = d.x - dx, qy = d.y - dy
            num1 += px * qx + py * qy
            num2 += px * qy - py * qx
            den += px * px + py * py
        }
        guard den > 0 else { return nil }
        let a = num1 / den, b = num2 / den
        // x' = a x - b y + tx ; y' = b x + a y + ty
        let tx = dx - (a * sx - b * sy), ty = dy - (b * sx + a * sy)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    // MARK: Image statistics

    static func grayscale(_ image: CGImage, maxSide: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (pixels, w, h)
    }

    /// Sharpness: variance of the 4-neighbour Laplacian.
    static func laplacianVariance(_ p: [UInt8], width w: Int, height h: Int) -> Double {
        guard w > 2, h > 2 else { return 0 }
        var sum = 0.0, sumSq = 0.0
        var n = 0.0
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                let v = Double(p[i - w]) + Double(p[i + w]) + Double(p[i - 1]) + Double(p[i + 1]) - 4 * Double(p[i])
                sum += v
                sumSq += v * v
                n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// 9×8 difference hash.
    static func differenceHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) where pixels[y * w + x] > pixels[y * w + x + 1] {
                hash |= 1 << UInt64(y * 8 + x)
            }
        }
        return hash
    }
}
