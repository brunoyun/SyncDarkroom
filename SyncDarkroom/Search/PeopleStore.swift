import Foundation
import Observation

struct Person: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var isHidden = false
    /// Face shown for this person.
    var cover: String?

    var displayName: String { name.isEmpty ? "Unnamed" : name }
}

/// One detected face: "<photo path>#<index>".
struct FaceRef: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let box: CGRect
    var roll: Double = 0
    let date: Date
}

/// Groups faces into people, like Immich: faces close enough to a person's faces are added to
/// them; the user names, merges, hides and corrects people. Kept on this iPad per folder.
@MainActor
@Observable
final class PeopleStore {
    static let shared = PeopleStore()

    struct Saved: Codable, Sendable {
        var people: [Person] = []
        var assignment: [String: UUID] = [:]
        /// Faces the user named, merged or moved: never regrouped automatically.
        var confirmed: Set<String> = []
        /// Faces the user removed from a person: never put back with them.
        var rejected: [String: Set<UUID>] = [:]
        /// Cosine similarity needed to join a person (higher = stricter).
        var strictness: Float = 0.5
    }

    private(set) var root: URL?
    private(set) var saved = Saved()
    private(set) var facesByPerson: [UUID: [FaceRef]] = [:]
    private(set) var faces: [String: FaceRef] = [:]
    private(set) var isGrouping = false
    @ObservationIgnored private var embeddings: [String: [Float]] = [:]
    @ObservationIgnored private var groupedRevision = -1
    @ObservationIgnored private var groupTask: Task<Void, Never>?
    /// An update arrived while grouping: run it once grouping finishes.
    @ObservationIgnored private var pendingUpdate: (() -> Void)?

    var people: [Person] { saved.people }

    func person(_ id: UUID) -> Person? { saved.people.first { $0.id == id } }

    func faceCount(_ id: UUID) -> Int { facesByPerson[id]?.count ?? 0 }

    /// Named people first (alphabetically), then by number of photos.
    func sortedPeople(includeHidden: Bool = false, minimumFaces: Int = 1) -> [Person] {
        saved.people
            .filter { (includeHidden || !$0.isHidden) && (faceCount($0.id) >= minimumFaces || !$0.name.isEmpty) && faceCount($0.id) > 0 }
            .sorted { a, b in
                if a.name.isEmpty != b.name.isEmpty { return !a.name.isEmpty }
                if !a.name.isEmpty { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return faceCount(a.id) > faceCount(b.id)
            }
    }

    func photoPaths(of id: UUID) -> Set<String> { Set((facesByPerson[id] ?? []).map(\.path)) }

    /// People found in a photo.
    func people(inPhoto path: String) -> [Person] {
        let ids = Set(faces.values.filter { $0.path == path }.compactMap { saved.assignment[$0.id] })
        return saved.people.filter { ids.contains($0.id) }
    }

    func coverFace(of person: Person) -> FaceRef? {
        if let cover = person.cover, let face = faces[cover], saved.assignment[cover] == person.id { return face }
        return facesByPerson[person.id]?.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
    }

    // MARK: Loading & grouping

    func load(root: URL) {
        guard self.root != root else { return }
        groupTask?.cancel()
        self.root = root
        saved = Self.loadFile(root: root)
        faces = [:]
        facesByPerson = [:]
        embeddings = [:]
        groupedRevision = -1
    }

    /// Adds newly analyzed faces to people. Cheap when nothing changed.
    func update(index: PhotoIndex, analysis: PhotoAnalysisStore, root: URL, force: Bool = false) {
        load(root: root)
        if isGrouping {
            pendingUpdate = { [weak self] in self?.update(index: index, analysis: analysis, root: root, force: force) }
            return
        }
        guard force || analysis.revision != groupedRevision else { return }
        groupedRevision = analysis.revision

        var allFaces: [String: FaceRef] = [:]
        var vectors: [String: [Float]] = [:]
        for photo in index.photos where !photo.isEditedCopy {
            guard let f = analysis.features(for: photo) else { continue }
            for (i, face) in f.faces.enumerated() where !face.embedding.isEmpty {
                let id = "\(photo.path)#\(i)"
                allFaces[id] = FaceRef(id: id, path: photo.path, box: face.box, roll: face.roll ?? 0, date: photo.date)
                vectors[id] = embeddings[id] ?? face.embedding.floats
            }
        }
        faces = allFaces
        embeddings = vectors
        regroup()
    }

    private func regroup() {
        var state = saved
        // Forget faces that no longer exist.
        state.assignment = state.assignment.filter { faces[$0.key] != nil }
        state.confirmed = state.confirmed.filter { faces[$0] != nil }
        state.rejected = state.rejected.filter { faces[$0.key] != nil }
        let unassigned = faces.values.filter { state.assignment[$0.id] == nil }.sorted { $0.date < $1.date }
        guard !unassigned.isEmpty else {
            apply(state)
            return
        }
        isGrouping = true
        let vectors = embeddings
        let snapshot = state
        groupTask = Task {
            let result = await Task.detached(priority: .utility) {
                Self.assign(unassigned, state: snapshot, vectors: vectors)
            }.value
            guard !Task.isCancelled else { return }
            isGrouping = false
            apply(result)
            if let next = pendingUpdate {
                pendingUpdate = nil
                next()
            }
        }
    }

    /// Greedy grouping: each face joins the most similar person (by mean embedding) when similar
    /// enough, never a person already in the same photo; otherwise it starts a new person.
    nonisolated private static func assign(_ unassigned: [FaceRef], state input: Saved, vectors: [String: [Float]]) -> Saved {
        var state = input
        var sums: [UUID: [Float]] = [:]
        var photosOf: [UUID: Set<String>] = [:]
        func pathOf(_ faceID: String) -> String { String(faceID[..<(faceID.lastIndex(of: "#") ?? faceID.endIndex)]) }
        for (faceID, person) in state.assignment {
            guard let v = vectors[faceID] else { continue }
            if var s = sums[person] {
                for i in s.indices { s[i] += v[i] }
                sums[person] = s
            } else {
                sums[person] = v
            }
            photosOf[person, default: []].insert(pathOf(faceID))
        }
        var ids = Array(sums.keys)
        var centroids: [[Float]] = ids.map { normalized(sums[$0]!) }

        for face in unassigned {
            guard let v = vectors[face.id] else { continue }
            let rejected = state.rejected[face.id] ?? []
            var best = -1
            var bestScore = state.strictness
            for (i, c) in centroids.enumerated() {
                let score = VectorMath.dot(v, c)
                guard score > bestScore else { continue }
                let id = ids[i]
                if rejected.contains(id) || photosOf[id]?.contains(face.path) == true { continue }
                best = i
                bestScore = score
            }
            let person: UUID
            if best >= 0 {
                person = ids[best]
                var s = sums[person]!
                for i in s.indices { s[i] += v[i] }
                sums[person] = s
                centroids[best] = normalized(s)
            } else {
                let new = Person()
                state.people.append(new)
                person = new.id
                ids.append(person)
                sums[person] = v
                centroids.append(v)
            }
            state.assignment[face.id] = person
            photosOf[person, default: []].insert(face.path)
        }
        return state
    }

    nonisolated private static func normalized(_ v: [Float]) -> [Float] {
        let n = VectorMath.dot(v, v).squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    private func apply(_ state: Saved) {
        var byPerson: [UUID: [FaceRef]] = [:]
        for (faceID, person) in state.assignment {
            if let face = faces[faceID] { byPerson[person, default: []].append(face) }
        }
        var state = state
        // People without faces disappear.
        state.people.removeAll { byPerson[$0.id] == nil }
        for key in byPerson.keys { byPerson[key]?.sort { $0.date > $1.date } }
        facesByPerson = byPerson
        saved = state
        save()
    }

    // MARK: Editing

    private func confirmFaces(of id: UUID) {
        for face in facesByPerson[id] ?? [] { saved.confirmed.insert(face.id) }
    }

    /// Another person already called `name`, if any.
    func existingPerson(named name: String, except id: UUID) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return saved.people.first { $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = saved.people.firstIndex(where: { $0.id == id }) else { return }
        saved.people[i].name = name.trimmingCharacters(in: .whitespaces)
        confirmFaces(of: id)
        save()
    }

    /// Moves the faces of `others` into `target`; the target keeps its name, or takes the first other name.
    func merge(_ others: [UUID], into target: UUID) {
        guard let t = saved.people.firstIndex(where: { $0.id == target }) else { return }
        if saved.people[t].name.isEmpty,
           let name = others.compactMap({ person($0)?.name }).first(where: { !$0.isEmpty }) {
            saved.people[t].name = name
        }
        let merged = Set(others).subtracting([target])
        for (faceID, person) in saved.assignment where merged.contains(person) {
            saved.assignment[faceID] = target
        }
        for (faceID, set) in saved.rejected where !set.isDisjoint(with: merged) {
            saved.rejected[faceID] = set.subtracting(merged).union([target])
        }
        saved.people.removeAll { merged.contains($0.id) }
        apply(saved)
        confirmFaces(of: target)
        save()
    }

    func setHidden(_ id: UUID, _ hidden: Bool) {
        guard let i = saved.people.firstIndex(where: { $0.id == id }) else { return }
        saved.people[i].isHidden = hidden
        save()
    }

    func setCover(_ faceID: String, for id: UUID) {
        guard let i = saved.people.firstIndex(where: { $0.id == id }) else { return }
        saved.people[i].cover = faceID
        save()
    }

    /// "Not this person": moves a face to another person, or to a new one when `to` is nil.
    func move(_ faceID: String, to destination: UUID?) {
        if let current = saved.assignment[faceID] {
            saved.rejected[faceID, default: []].insert(current)
        }
        let target: UUID
        if let destination {
            target = destination
            saved.rejected[faceID]?.remove(destination)
        } else {
            let new = Person()
            saved.people.append(new)
            target = new.id
        }
        saved.assignment[faceID] = target
        saved.confirmed.insert(faceID)
        apply(saved)
    }

    /// Regroups every face the user hasn't confirmed, with a new strictness.
    func regroup(strictness: Float) {
        saved.strictness = strictness
        let keep = saved.confirmed
        saved.assignment = saved.assignment.filter { keep.contains($0.key) }
        regroup()
    }

    // MARK: Persistence

    nonisolated private static func fileURL(root: URL) -> URL {
        AppStorageFiles.url("people-\(AppStorageFiles.key(for: root)).json")
    }

    nonisolated private static func loadFile(root: URL) -> Saved {
        guard let data = try? Data(contentsOf: fileURL(root: root)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    private func save() {
        guard let root else { return }
        let snapshot = saved
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL(root: root), options: .atomic)
        }
    }
}
