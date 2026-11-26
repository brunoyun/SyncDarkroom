import Foundation

enum ImageType: String, CaseIterable, Sendable {
    case jpeg, heic, png, tiff, raw, other

    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf",
        "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "mos", "mrw", "rwl",
    ]

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "heic", "heif", "hif": self = .heic
        case "png": self = .png
        case "tif", "tiff": self = .tiff
        case "webp", "gif", "bmp", "avif": self = .other
        case let e where Self.rawExtensions.contains(e): self = .raw
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .raw: "RAW"
        case .other: "Other"
        }
    }
}

struct LibraryItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isFolder: Bool
    let type: ImageType?
    let modified: Date
    let fileSize: Int64
    /// The original has an edit recipe in `.syncdarkroom/`.
    var hasEdits = false
    /// The file's own modification date. `modified` is the date used for sorting, which for
    /// edited copies is their original's, so it doesn't change when the copy itself changes.
    var fileDate: Date?

    /// Changes whenever the file's content does (used to refresh thumbnails).
    var contentKey: String {
        "\((fileDate ?? modified).timeIntervalSince1970)|\(fileSize)"
    }

    var id: URL { url }

    /// Copies written by the editor are named `<original>_edit.<ext>`.
    var isEditedCopy: Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix("_edit")
    }
}

enum FolderScanner {
    static func scan(_ folder: URL) throws -> [LibraryItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles] // also skips Syncthing's .stfolder/.stversions and our .syncdarkroom
        )
        let copySources = SidecarStore.copySources(in: folder)
        let edited = Set(copySources.values)
        var dates: [String: Date] = [:]
        for url in urls {
            dates[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            let type = isFolder ? nil : ImageType(fileExtension: url.pathExtension)
            guard isFolder || type != nil else { return nil }
            return LibraryItem(
                url: url,
                name: url.lastPathComponent,
                isFolder: isFolder,
                type: type,
                // Edited copies take their original's date, so they sit next to it in the grid.
                modified: copySources[url.lastPathComponent].flatMap { dates[$0] }
                    ?? values?.contentModificationDate ?? .distantPast,
                fileSize: Int64(values?.fileSize ?? 0),
                hasEdits: edited.contains(url.lastPathComponent),
                fileDate: values?.contentModificationDate
            )
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case dateNewest, dateOldest, nameAscending, nameDescending, sizeLargest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateNewest: "Date (Newest First)"
        case .dateOldest: "Date (Oldest First)"
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        case .sizeLargest: "File Size (Largest First)"
        }
    }

    func sorted(_ items: [LibraryItem]) -> [LibraryItem] {
        switch self {
        case .dateNewest: items.sorted { $0.modified > $1.modified }
        case .dateOldest: items.sorted { $0.modified < $1.modified }
        case .nameAscending: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeLargest: items.sorted { $0.fileSize > $1.fileSize }
        }
    }
}

enum TypeFilter: String, CaseIterable, Identifiable {
    case all, jpeg, heic, png, tiff, raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All Photos"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .raw: "RAW"
        }
    }

    func matches(_ type: ImageType?) -> Bool {
        switch self {
        case .all: true
        case .jpeg: type == .jpeg
        case .heic: type == .heic
        case .png: type == .png
        case .tiff: type == .tiff
        case .raw: type == .raw
        }
    }
}
