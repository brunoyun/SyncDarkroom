import Foundation
import ImageIO
import UIKit

enum ImageLoading {
    /// Reads a file through NSFileCoordinator so File Provider–backed folders
    /// (such as Synctrain's) can materialize the file before we read it.
    static func coordinatedRead<T>(_ url: URL, _ body: (URL) -> T?) -> T? {
        var coordinationError: NSError?
        var output: T?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            output = body(readURL)
        }
        return output
    }

    /// Decodes a downsampled, orientation-corrected image without loading the full-size bitmap.
    static func downsampled(url: URL, maxPixelSize: Int) -> UIImage? {
        coordinatedRead(url) { readURL in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(readURL as CFURL, sourceOptions) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }
}

/// Limits how many images decode at once so fast scrolling doesn't spike memory.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let limiter = AsyncLimiter(limit: 4)

    private init() {
        cache.countLimit = 800
    }

    func image(for item: LibraryItem, maxPixelSize: Int) async -> UIImage? {
        let key = "\(item.url.path)|\(maxPixelSize)|\(item.modified.timeIntervalSince1970)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        await limiter.acquire()
        guard !Task.isCancelled else {
            await limiter.release()
            return nil
        }
        let url = item.url
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoading.downsampled(url: url, maxPixelSize: maxPixelSize)
        }.value
        await limiter.release()

        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
