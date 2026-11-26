import CryptoKit
import Foundation

enum CleanupAnalyzer {
    static let screenLabels = ["computer_monitor", "television", "laptop", "screenshot"]
    static let documentLabels = ["document", "receipt"]

    static func fileHash(_ url: URL) -> String? {
        ImageLoading.coordinatedRead(url) { readURL in
            guard let handle = try? FileHandle(forReadingFrom: readURL) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Near-identical shots: Vision scene prints when available, else the difference hash.
    static func areSimilar(_ a: PhotoFeatures, _ aPrint: [Float]?, _ b: PhotoFeatures, _ bPrint: [Float]?) -> Bool {
        if let aPrint, let bPrint, aPrint.count == bPrint.count {
            return VectorMath.distance(aPrint, bPrint) < 0.35
        }
        return (a.dHash ^ b.dHash).nonzeroBitCount <= 5
    }
}

/// Photos the user chose to ignore in each "Find Photos to Delete" category. Kept in
/// `.syncdarkroom/cleanup-ignored.json` at the root, so it syncs with the folder.
struct CleanupIgnoreList: Codable, Sendable {
    var categories: [String: Set<String>] = [:]

    static func url(root: URL) -> URL {
        root.appendingPathComponent(SidecarStore.directoryName, isDirectory: true)
            .appendingPathComponent("cleanup-ignored.json")
    }

    static func load(root: URL) -> CleanupIgnoreList {
        ImageLoading.coordinatedRead(url(root: root)) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return nil }
            return try? JSONDecoder().decode(CleanupIgnoreList.self, from: data)
        } ?? CleanupIgnoreList()
    }

    func save(root: URL) throws {
        let url = Self.url(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try coordinatedWrite(to: url) { target in try data.write(to: target, options: .atomic) }
    }
}
