import CryptoKit
import Foundation
import ImageIO
import Observation

/// Where per-folder data that must survive (unlike caches) is kept on this iPad.
enum AppStorageFiles {
    static func key(for root: URL) -> String {
        SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncDarkroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

/// On-device analysis of every photo (objects, faces, CLIP embedding, sharpness, hashes),
/// shared by search and "Find Photos to Delete". Results are kept on disk, so a photo is
/// only analyzed again when its file changes.
@MainActor
@Observable
final class PhotoAnalysisStore {
    static let shared = PhotoAnalysisStore()

    private(set) var root: URL?
    private(set) var features: [String: PhotoFeatures] = [:]
    /// Bumped whenever results change.
    private(set) var revision = 0
    /// Photos waiting or being analyzed.
    private(set) var pendingCount = 0
    /// Photos finished since the queue was last empty (for progress).
    private(set) var finishedCount = 0
    /// Background indexing is paused (requests from Find Photos to Delete still run).
    var isPaused: Bool = UserDefaults.standard.bool(forKey: "analysisPaused") {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "analysisPaused")
            if !isPaused { startWorker() }
        }
    }

    var isWorking: Bool { pendingCount > 0 && (!isPaused || hasForegroundJobs) }

    private struct Job: Sendable {
        let path: String
        let url: URL
        let size: Int64
        let modified: Date
        var foreground: Bool
    }

    @MainActor
    private final class Request {
        var remaining: Set<String>
        let total: Int
        let progress: @MainActor (Int, Int) -> Void
        var continuation: CheckedContinuation<Void, Never>?
        init(remaining: Set<String>, progress: @escaping @MainActor (Int, Int) -> Void) {
            self.remaining = remaining
            total = remaining.count
            self.progress = progress
        }
    }

    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var requests: [Request] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var unsaved = 0
    @ObservationIgnored private var lastSave = Date()
    /// Saves run one after another, so an older snapshot never overwrites a newer one.
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var hasForegroundJobs: Bool { queue.contains(where: \.foreground) }

    // MARK: Loading

    func load(root: URL) {
        guard self.root != root else { return }
        worker?.cancel()
        worker = nil
        queue.removeAll()
        running.removeAll()
        for request in requests { request.continuation?.resume() }
        requests.removeAll()
        pendingCount = 0
        finishedCount = 0
        attempted.removeAll()
        self.root = root
        features = Self.loadFile(root: root)
        revision += 1
    }

    /// Valid (up-to-date) features of a photo.
    func features(for photo: IndexedPhoto) -> PhotoFeatures? {
        guard let f = features[photo.path], f.size == photo.size, f.modified == photo.modified else { return nil }
        return f
    }

    func needsAnalysis(_ photo: IndexedPhoto) -> Bool {
        guard let f = features[photo.path], f.version == PhotoFeatures.currentVersion,
              f.size == photo.size, f.modified == photo.modified else { return true }
        // Retry what couldn't be computed, once per launch.
        let incomplete = !f.visionOK
            || (f.clip == nil && CLIPEncoder.shared != nil)
            || (FaceEncoder.shared != nil && f.faces.contains { $0.embedding.isEmpty })
        return incomplete && !attempted.contains(photo.path)
    }

    // MARK: Requests

    /// Analyzes the photos that need it, ahead of background work, and returns when all are done.
    func ensureAnalyzed(_ photos: [IndexedPhoto], root: URL, progress: @escaping @MainActor (Int, Int) -> Void) async {
        load(root: root)
        let todo = photos.filter(needsAnalysis)
        guard !todo.isEmpty else { progress(0, 0); return }
        let request = Request(remaining: Set(todo.map(\.path)), progress: progress)
        enqueue(todo, root: root, foreground: true)
        progress(0, request.total)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if request.remaining.isEmpty {
                    continuation.resume()
                } else {
                    request.continuation = continuation
                    requests.append(request)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(request) }
        }
    }

    private func cancel(_ request: Request) {
        guard let i = requests.firstIndex(where: { $0 === request }) else { return }
        requests.remove(at: i)
        for j in queue.indices where request.remaining.contains(queue[j].path) { queue[j].foreground = false }
        request.continuation?.resume()
        request.continuation = nil
    }

    /// Queues every original photo in the library for background analysis (newest first).
    func indexLibrary(_ photos: [IndexedPhoto], root: URL) {
        load(root: root)
        let paths = Set(photos.map(\.path))
        let stale = features.keys.filter { !paths.contains($0) }
        if !stale.isEmpty {
            for key in stale { features[key] = nil }
            revision += 1
            unsaved += stale.count
        }
        let todo = photos.filter { !$0.isEditedCopy && needsAnalysis($0) }.sorted { $0.date > $1.date }
        enqueue(todo, root: root, foreground: false)
    }

    private func enqueue(_ photos: [IndexedPhoto], root: URL, foreground: Bool) {
        var queuedIndex: [String: Int] = [:]
        for (i, job) in queue.enumerated() { queuedIndex[job.path] = i }
        var front: [Job] = []
        for photo in photos where !running.contains(photo.path) {
            if let i = queuedIndex[photo.path] {
                if foreground { queue[i].foreground = true }
                continue
            }
            let job = Job(path: photo.path, url: photo.url(root: root), size: photo.size,
                          modified: photo.modified, foreground: foreground)
            if foreground { front.append(job) } else { queue.append(job) }
        }
        if foreground {
            // Foreground work goes first.
            let promoted = queue.filter(\.foreground)
            queue = front + promoted + queue.filter { !$0.foreground }
        }
        pendingCount = queue.count + running.count
        startWorker()
    }

    private func nextJob() -> Job? {
        if let i = queue.firstIndex(where: \.foreground) { return queue.remove(at: i) }
        guard !isPaused, !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    // MARK: Worker

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await withTaskGroup(of: (String, PhotoFeatures?).self) { group in
                var active = 0
                @MainActor func fill() {
                    while active < 2, let job = self?.nextJob() {
                        self?.running.insert(job.path)
                        group.addTask(priority: .utility) { (job.path, Self.analyze(job)) }
                        active += 1
                    }
                }
                fill()
                while let (path, result) = await group.next() {
                    active -= 1
                    guard let self, !Task.isCancelled else { break }
                    self.finish(path, result)
                    fill()
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.worker = nil
            self.save()
            if self.queue.contains(where: { $0.foreground || !self.isPaused }) { self.startWorker() }
        }
    }

    private func finish(_ path: String, _ result: PhotoFeatures?) {
        running.remove(path)
        attempted.insert(path)
        if var result {
            // A file hash stays valid while the file is unchanged.
            if let old = features[path], old.size == result.size, old.modified == result.modified {
                result.sha256 = old.sha256
            }
            features[path] = result
            revision += 1
            unsaved += 1
        }
        finishedCount += 1
        pendingCount = queue.count + running.count
        if pendingCount == 0 { finishedCount = 0 }
        for request in requests where request.remaining.remove(path) != nil {
            request.progress(request.total - request.remaining.count, request.total)
            if request.remaining.isEmpty {
                request.continuation?.resume()
                request.continuation = nil
            }
        }
        requests.removeAll { $0.continuation == nil }
        if unsaved >= 40 || Date().timeIntervalSince(lastSave) > 20 { save() }
    }

    nonisolated private static func analyze(_ job: Job) -> PhotoFeatures? {
        guard let image = ImageLoading.coordinatedRead(job.url, { readURL -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(readURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
            ] as CFDictionary)
        }) else { return nil }
        return FeatureExtractor.extract(image, size: job.size, modified: job.modified,
                                        clip: CLIPEncoder.shared, faceEncoder: FaceEncoder.shared)
    }

    // MARK: File hashes

    /// SHA-256 of each photo's file, cached with the analysis.
    func fileHashes(_ photos: [IndexedPhoto], root: URL) async -> [String: String] {
        var result: [String: String] = [:]
        var missing: [IndexedPhoto] = []
        for photo in photos {
            if let hash = features(for: photo)?.sha256 { result[photo.path] = hash } else { missing.append(photo) }
        }
        guard !missing.isEmpty else { return result }
        let computed = await Task.detached(priority: .utility) {
            missing.map { ($0.path, CleanupAnalyzer.fileHash($0.url(root: root))) }
        }.value
        for (path, hash) in computed {
            guard let hash else { continue }
            result[path] = hash
            features[path]?.sha256 = hash
            unsaved += 1
        }
        save()
        return result
    }

    // MARK: Persistence

    nonisolated private static func fileURL(root: URL) -> URL {
        AppStorageFiles.url("analysis-\(AppStorageFiles.key(for: root)).plist")
    }

    nonisolated private static func loadFile(root: URL) -> [String: PhotoFeatures] {
        guard let data = try? Data(contentsOf: fileURL(root: root)),
              let decoded = try? PropertyListDecoder().decode([String: PhotoFeatures].self, from: data)
        else { return [:] }
        return decoded
    }

    func save() {
        guard unsaved > 0, let root else { return }
        unsaved = 0
        lastSave = Date()
        let snapshot = features
        let previous = saveTask
        saveTask = Task.detached(priority: .background) {
            await previous?.value
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: Self.fileURL(root: root), options: .atomic)
        }
    }
}
