import CryptoKit
import Foundation
import ImageIO
import Vision

/// What the cleanup scan learned about one photo.
struct PhotoAnalysis: @unchecked Sendable {
    /// Variance of the Laplacian on a 512 px grayscale copy: low = blurry.
    var sharpness: Double
    /// Vision labels → confidence (empty where Vision isn't available).
    var labels: [String: Float]
    /// 64-bit difference hash: near-duplicates differ in few bits.
    var dHash: UInt64
    var featurePrint: VNFeaturePrintObservation?
}

enum CleanupAnalyzer {
    static let screenLabels = ["computer_monitor", "television", "laptop", "screenshot"]
    static let documentLabels = ["document", "receipt"]

    static func analyze(_ url: URL) -> PhotoAnalysis? {
        guard let image = thumbnail(url, maxSide: 512) else { return nil }
        let gray = grayscale(image, maxSide: 512)
        var analysis = PhotoAnalysis(sharpness: laplacianVariance(gray.pixels, width: gray.width, height: gray.height),
                                     labels: [:], dHash: differenceHash(image), featurePrint: nil)

        let classify = VNClassifyImageRequest()
        let feature = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classify])
        try? handler.perform([feature])
        for observation in classify.results ?? [] where observation.confidence > 0.05 {
            analysis.labels[observation.identifier] = observation.confidence
        }
        analysis.featurePrint = feature.results?.first
        return analysis
    }

    // MARK: Image helpers

    private static func thumbnail(_ url: URL, maxSide: Int) -> CGImage? {
        ImageLoading.coordinatedRead(url) { readURL in
            guard let source = CGImageSourceCreateWithURL(readURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
            ] as CFDictionary)
        }
    }

    private static func grayscale(_ image: CGImage, maxSide: Int) -> (pixels: [UInt8], width: Int, height: Int) {
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
    private static func differenceHash(_ image: CGImage) -> UInt64 {
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

    static func fileHash(_ url: URL) -> String? {
        ImageLoading.coordinatedRead(url) { readURL in
            guard let handle = try? FileHandle(forReadingFrom: readURL) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: Similarity

    static func areSimilar(_ a: PhotoAnalysis, _ b: PhotoAnalysis) -> Bool {
        if let fa = a.featurePrint, let fb = b.featurePrint {
            var distance: Float = 0
            if (try? fa.computeDistance(&distance, to: fb)) != nil { return distance < 0.35 }
        }
        return (a.dHash ^ b.dHash).nonzeroBitCount <= 5
    }
}
