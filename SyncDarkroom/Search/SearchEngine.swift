import Foundation
import Observation

enum SearchMode: String, CaseIterable, Identifiable {
    case smart, metadata, objects
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart"
        case .metadata: "Metadata"
        case .objects: "Objects"
        }
    }
    var prompt: String {
        switch self {
        case .smart: "Describe a photo: “dog on a beach at sunset”"
        case .metadata: "File name, camera, lens, place, person, year…"
        case .objects: "Things in the photo: dog, car, mountain…"
        }
    }
}

enum MediaKind: String, CaseIterable, Identifiable {
    case all, photos, raw, edited
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos (not RAW)"
        case .raw: "RAW"
        case .edited: "Edited Copies"
        }
    }
}

struct SearchFilters: Equatable {
    var people: Set<UUID> = []
    var place: String?
    var camera: String?
    var lens: String?
    var from: Date?
    var to: Date?
    var media: MediaKind = .all
    var includeEditedCopies = false

    var activeCount: Int {
        var n = people.isEmpty ? 0 : 1
        n += place == nil ? 0 : 1
        n += camera == nil ? 0 : 1
        n += lens == nil ? 0 : 1
        n += (from == nil && to == nil) ? 0 : 1
        n += media == .all ? 0 : 1
        n += includeEditedCopies ? 1 : 0
        return n
    }
}

struct SearchResult: Identifiable, Hashable {
    let photo: IndexedPhoto
    let score: Float
    var id: String { photo.path }
}

/// Runs searches over the photo index and the on-device analysis.
@MainActor
enum SearchEngine {
    static let index = PhotoIndex.shared
    static let analysis = PhotoAnalysisStore.shared
    static let people = PeopleStore.shared
    static let places = PlaceStore.shared

    /// Photos passing the filters.
    static func filtered(_ filters: SearchFilters) -> [IndexedPhoto] {
        var peoplePaths: Set<String>?
        for id in filters.people {
            let paths = people.photoPaths(of: id)
            peoplePaths = peoplePaths.map { $0.intersection(paths) } ?? paths
        }
        let dayEnd = filters.to.map { Calendar.current.startOfDay(for: $0).addingTimeInterval(86_400) }
        return index.photos.filter { p in
            switch filters.media {
            case .all: if p.isEditedCopy && !filters.includeEditedCopies { return false }
            case .photos: if p.type == .raw || (p.isEditedCopy && !filters.includeEditedCopies) { return false }
            case .raw: if p.type != .raw { return false }
            case .edited: if !p.isEditedCopy { return false }
            }
            if let peoplePaths, !peoplePaths.contains(p.path) { return false }
            if let place = filters.place, places.place(for: p)?.title != place { return false }
            if let camera = filters.camera, p.camera != camera { return false }
            if let lens = filters.lens, p.lens != lens { return false }
            if let from = filters.from, p.date < Calendar.current.startOfDay(for: from) { return false }
            if let dayEnd, p.date >= dayEnd { return false }
            return true
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static let monthFormatters: [DateFormatter] = [Locale.current, Locale(identifier: "en_US")].map {
        let f = DateFormatter()
        f.locale = $0
        f.dateFormat = "MMMM yyyy"
        return f
    }

    /// Everything a metadata search matches against, folded to lowercase without accents.
    static func searchableText(_ p: IndexedPhoto, personNames: [String: [String]]) -> String {
        var parts: [String] = [p.name, p.folder, p.camera ?? "", p.lens ?? "", p.software ?? "",
                               p.type?.label ?? "", p.isEditedCopy ? "edited edit copy" : ""]
        parts += monthFormatters.map { $0.string(from: p.date) }
        if let place = places.place(for: p) { parts.append(place.searchText) }
        parts += personNames[p.path] ?? []
        if let f = analysis.features(for: p) {
            parts += f.labels.filter { $0.value >= 0.3 }.keys.map { $0.replacingOccurrences(of: "_", with: " ") }
        }
        return parts.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func metadataSearch(_ text: String, in photos: [IndexedPhoto]) -> [SearchResult] {
        let words = tokens(text)
        guard !words.isEmpty else { return photos.sorted { $0.date > $1.date }.map { SearchResult(photo: $0, score: 0) } }
        var names: [String: [String]] = [:]
        for person in people.people where !person.name.isEmpty {
            for path in people.photoPaths(of: person.id) { names[path, default: []].append(person.name) }
        }
        return photos.filter { p in
            let hay = searchableText(p, personNames: names)
            return words.allSatisfy { hay.contains($0) }
        }
        .sorted { $0.date > $1.date }
        .map { SearchResult(photo: $0, score: 0) }
    }

    /// Photos whose Vision labels match every word (a label matches when one of its words starts with the word).
    static func objectSearch(_ text: String, in photos: [IndexedPhoto]) -> [SearchResult] {
        let words = tokens(text)
        guard !words.isEmpty else { return [] }
        var results: [SearchResult] = []
        for p in photos {
            guard let f = analysis.features(for: p) else { continue }
            var total: Float = 0
            var all = true
            for word in words {
                var best: Float = 0
                for (label, confidence) in f.labels where confidence >= 0.2 {
                    if label.split(separator: "_").contains(where: { $0.hasPrefix(word) }) { best = max(best, confidence) }
                }
                if best == 0 { all = false; break }
                total += best
            }
            if all { results.append(SearchResult(photo: p, score: total / Float(words.count))) }
        }
        return results.sorted { $0.score > $1.score }
    }

    /// Ranks photos by CLIP similarity to an embedding (text or another photo), best first.
    static func rank(by embedding: [Float], in photos: [IndexedPhoto], limit: Int = 400) -> [SearchResult] {
        var results: [SearchResult] = []
        results.reserveCapacity(photos.count)
        for p in photos {
            guard let data = analysis.features(for: p)?.clip else { continue }
            results.append(SearchResult(photo: p, score: VectorMath.dot(embedding, data.floats)))
        }
        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    static func clipEmbedding(of photo: IndexedPhoto) -> [Float]? {
        analysis.features(for: photo)?.clip?.floats
    }

    /// Number of photos (excluding edited copies) with a CLIP embedding / analyzed at all.
    static func coverage() -> (clip: Int, analyzed: Int, total: Int) {
        var clip = 0, analyzed = 0, total = 0
        for p in index.photos where !p.isEditedCopy {
            total += 1
            if let f = analysis.features(for: p) {
                analyzed += 1
                if f.clip != nil { clip += 1 }
            }
        }
        return (clip, analyzed, total)
    }

    // MARK: Explore

    struct Bucket: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        let photos: [IndexedPhoto]
        var cover: IndexedPhoto { photos.max { $0.date < $1.date } ?? photos[0] }
    }

    static func placeBuckets() -> [Bucket] {
        var groups: [String: (PlaceName, [IndexedPhoto])] = [:]
        for p in index.photos where !p.isEditedCopy {
            guard let place = places.place(for: p) else { continue }
            groups[place.title, default: (place, [])].1.append(p)
        }
        return groups.map { Bucket(id: $0.key, title: $0.key, subtitle: $0.value.0.subtitle, photos: $0.value.1) }
            .sorted { $0.photos.count > $1.photos.count }
    }

    /// Labels too generic to be interesting on their own.
    private static let genericLabels: Set<String> = ["people", "adult", "structure", "outdoor", "indoor", "clothing",
                                                     "material", "textile", "wood_processed", "machine", "conveyance"]

    static func thingBuckets(limit: Int = 40) -> [Bucket] {
        var groups: [String: [IndexedPhoto]] = [:]
        for p in index.photos where !p.isEditedCopy {
            guard let f = analysis.features(for: p) else { continue }
            for (label, confidence) in f.labels where confidence >= 0.5 && !genericLabels.contains(label) {
                groups[label, default: []].append(p)
            }
        }
        return groups.filter { $0.value.count >= 2 }
            .map { Bucket(id: $0.key, title: $0.key.replacingOccurrences(of: "_", with: " ").capitalized, photos: $0.value) }
            .sorted { $0.photos.count > $1.photos.count }
            .prefix(limit).map { $0 }
    }

    static func cameraBuckets() -> [Bucket] {
        Dictionary(grouping: index.photos.filter { !$0.isEditedCopy && $0.camera != nil }) { $0.camera! }
            .map { Bucket(id: $0.key, title: $0.key, photos: $0.value) }
            .sorted { $0.photos.count > $1.photos.count }
    }

    static func lensNames() -> [String] {
        Array(Set(index.photos.compactMap(\.lens))).sorted()
    }
}
