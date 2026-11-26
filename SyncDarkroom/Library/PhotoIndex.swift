import CryptoKit
import Foundation
import ImageIO
import Observation

/// Header-level facts about one photo, cached between launches.
struct IndexedPhoto: Codable, Hashable, Sendable, Identifiable {
    /// Path relative to the root folder.
    var path: String
    var size: Int64
    var modified: Date
    var dateTaken: Date?
    var make: String?
    var model: String?
    var lens: String?
    var width: Int?
    var height: Int?
    var latitude: Double?
    var longitude: Double?
    var software: String?
    var userComment: String?
    var isEditedCopy: Bool
    /// The original has edited copies.
    var hasEdits: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var type: ImageType? { ImageType(fileExtension: (path as NSString).pathExtension) }
    var date: Date { dateTaken ?? modified }
    /// A usable GPS position (cameras without a fix often write 0, 0).
    var hasLocation: Bool {
        guard let latitude, let longitude else { return false }
        return GeoCoordinate.isValid(latitude: latitude, longitude: longitude)
    }
    var pixelCount: Int { (width ?? 0) * (height ?? 0) }
    var camera: String? {
        guard let model else { return make }
        if let make, !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "") {
            return "\(make) \(model)"
        }
        return model
    }

    func url(root: URL) -> URL { root.appendingPathComponent(path) }

    func libraryItem(root: URL) -> LibraryItem {
        LibraryItem(url: url(root: root), name: name, isFolder: false, type: type,
                    modified: modified, fileSize: size, hasEdits: hasEdits)
    }
}

enum GeoCoordinate {
    static func isValid(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        // "Null Island": an empty GPS record, not a photo taken in the Gulf of Guinea.
        return !(abs(latitude) < 0.0001 && abs(longitude) < 0.0001)
    }
}

/// Recursive index of every photo under the root folder, shared by statistics, cleanup and the map.
@MainActor
@Observable
final class PhotoIndex {
    static let shared = PhotoIndex()

    private(set) var root: URL?
    private(set) var photos: [IndexedPhoto] = []
    private(set) var isScanning = false
    private(set) var scanned = 0
    private(set) var toScan = 0
    private(set) var lastUpdated: Date?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// Starts (or restarts) a scan; cached entries for unchanged files are reused.
    func refresh(root: URL) {
        if self.root != root {
            self.root = root
            photos = Self.loadCache(root: root)
        }
        scanTask?.cancel()
        scanTask = Task { await scan(root: root) }
    }

    func refreshIfNeeded(root: URL) {
        if self.root != root || (lastUpdated.map { Date().timeIntervalSince($0) > 30 } ?? true) {
            refresh(root: root)
        }
    }

    private func scan(root: URL) async {
        isScanning = true
        defer { isScanning = false }
        let cached = Dictionary(photos.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        let files = await Task.detached(priority: .utility) { Self.listFiles(root: root) }.value
        guard !Task.isCancelled else { return }
        toScan = files.count
        scanned = 0

        var result: [IndexedPhoto] = []
        result.reserveCapacity(files.count)
        var batch: [FileEntry] = []
        for file in files {
            if let hit = cached[file.path], hit.size == file.size, hit.modified == file.modified,
               hit.isEditedCopy == file.isEditedCopy, hit.hasEdits == file.hasEdits {
                result.append(hit)
                scanned += 1
            } else {
                batch.append(file)
            }
            if batch.count == 64 {
                result += await Self.read(batch, root: root)
                scanned += batch.count
                batch.removeAll()
                if Task.isCancelled { return }
            }
        }
        result += await Self.read(batch, root: root)
        scanned = toScan
        guard !Task.isCancelled else { return }
        photos = result
        lastUpdated = Date()
        let snapshot = result
        Task.detached(priority: .background) { Self.saveCache(snapshot, root: root) }
    }

    // MARK: File listing & metadata

    struct FileEntry: Sendable {
        let path: String
        let size: Int64
        let modified: Date
        let isEditedCopy: Bool
        let hasEdits: Bool
    }

    nonisolated private static func listFiles(root: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var entries: [FileEntry] = []
        var sidecarsByFolder: [URL: [String: String]] = [:]
        var foldersDates: [URL: [String: Date]] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true,
                  ImageType(fileExtension: url.pathExtension) != nil else { continue }
            let folder = url.deletingLastPathComponent()
            if sidecarsByFolder[folder] == nil { sidecarsByFolder[folder] = SidecarStore.copySources(in: folder) }
            let copies = sidecarsByFolder[folder] ?? [:]
            let name = url.lastPathComponent
            var modified = values.contentModificationDate ?? .distantPast
            // Edited copies are dated like their original (same rule as the library grid).
            if let source = copies[name] {
                if foldersDates[folder] == nil {
                    var dates: [String: Date] = [:]
                    for original in Set(copies.values) {
                        dates[original] = (try? folder.appendingPathComponent(original)
                            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    }
                    foldersDates[folder] = dates
                }
                modified = foldersDates[folder]?[source] ?? modified
            }
            var path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath) { path = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            entries.append(FileEntry(path: path, size: Int64(values.fileSize ?? 0), modified: modified,
                                     isEditedCopy: copies[name] != nil || name.lowercased().contains("_edit."),
                                     hasEdits: Set(copies.values).contains(name)))
        }
        return entries
    }

    nonisolated private static func read(_ batch: [FileEntry], root: URL) async -> [IndexedPhoto] {
        guard !batch.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            batch.map { entry in
                var photo = IndexedPhoto(path: entry.path, size: entry.size, modified: entry.modified,
                                         isEditedCopy: entry.isEditedCopy, hasEdits: entry.hasEdits)
                let url = root.appendingPathComponent(entry.path)
                // Header only: no pixel decoding.
                if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    let meta = PhotoMetadata(properties: props)
                    photo.dateTaken = meta.dateTaken
                    photo.make = meta.make
                    photo.model = meta.model
                    photo.lens = meta.lens
                    photo.width = meta.pixelWidth
                    photo.height = meta.pixelHeight
                    photo.latitude = meta.latitude
                    photo.longitude = meta.longitude
                    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                    photo.software = tiff?[kCGImagePropertyTIFFSoftware] as? String
                    photo.userComment = exif?[kCGImagePropertyExifUserComment] as? String
                }
                return photo
            }
        }.value
    }

    // MARK: Cache

    nonisolated private static func cacheURL(root: URL) -> URL {
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("photo-index-\(key).json")
    }

    nonisolated private static func loadCache(root: URL) -> [IndexedPhoto] {
        guard let data = try? Data(contentsOf: cacheURL(root: root)) else { return [] }
        return (try? JSONDecoder().decode([IndexedPhoto].self, from: data)) ?? []
    }

    nonisolated private static func saveCache(_ photos: [IndexedPhoto], root: URL) {
        guard let data = try? JSONEncoder().encode(photos) else { return }
        try? data.write(to: cacheURL(root: root), options: .atomic)
    }
}
