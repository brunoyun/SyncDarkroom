import Observation
import SwiftUI

enum CleanupCategory: String, CaseIterable, Identifiable {
    case screenshots, screens, documents, duplicates, blurry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .screens: "Photos of Screens"
        case .documents: "Documents & Receipts"
        case .duplicates: "Duplicates & Similar"
        case .blurry: "Blurry"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .screens: "tv"
        case .documents: "doc.text"
        case .duplicates: "square.on.square"
        case .blurry: "aqi.medium"
        }
    }

    var explanation: String {
        switch self {
        case .screenshots: "Screenshots and screen captures saved into the folder."
        case .screens: "Camera photos of a monitor, TV or laptop screen."
        case .documents: "Photos of papers, documents and receipts."
        case .duplicates: "Identical files and near-identical shots. The best of each group (highest resolution, then sharpest) is kept; the others are selected."
        case .blurry: "Photos with little fine detail. Move the slider to find more or fewer."
        }
    }
}

@MainActor
@Observable
final class CleanupModel {
    struct Group: Identifiable {
        let id = UUID()
        var photos: [IndexedPhoto]
        var keep: String?
    }

    private(set) var isScanning = false
    private(set) var analyzed = 0
    private(set) var total = 0
    private(set) var hasResults = false
    private(set) var screenshots: [IndexedPhoto] = []
    private(set) var screens: [IndexedPhoto] = []
    private(set) var documents: [IndexedPhoto] = []
    private(set) var allDuplicateGroups: [Group] = []
    private(set) var sharpness: [String: Double] = [:]
    private(set) var ignored = CleanupIgnoreList()
    private var candidates: [IndexedPhoto] = []
    private var root: URL?
    var blurThreshold: Double = 40
    var selection: Set<String> = []
    /// Show the ignored photos of the current category instead of the others.
    var showingIgnored = false
    @ObservationIgnored private var task: Task<Void, Never>?

    private var blurryAll: [IndexedPhoto] {
        candidates.filter { (sharpness[$0.path] ?? .infinity) < blurThreshold }
            .sorted { (sharpness[$0.path] ?? 0) < (sharpness[$1.path] ?? 0) }
    }

    private func found(_ category: CleanupCategory) -> [IndexedPhoto] {
        switch category {
        case .screenshots: screenshots
        case .screens: screens
        case .documents: documents
        case .duplicates: allDuplicateGroups.flatMap(\.photos)
        case .blurry: blurryAll
        }
    }

    func ignoredPaths(_ category: CleanupCategory) -> Set<String> { ignored.categories[category.rawValue] ?? [] }

    /// What the category shows: the photos found minus the ignored ones (or only those when showing ignored).
    func photos(in category: CleanupCategory) -> [IndexedPhoto] {
        let skip = ignoredPaths(category)
        return found(category).filter { skip.contains($0.path) == showingIgnored }
    }

    func ignoredCount(_ category: CleanupCategory) -> Int {
        let skip = ignoredPaths(category)
        return found(category).filter { skip.contains($0.path) }.count
    }

    /// Duplicate groups without ignored photos (a group left with one photo disappears).
    var duplicateGroups: [Group] {
        let skip = ignoredPaths(.duplicates)
        return allDuplicateGroups.compactMap { group in
            var g = group
            g.photos.removeAll { skip.contains($0.path) }
            if let keep = g.keep, skip.contains(keep) { g.keep = g.photos.first?.path }
            return g.photos.count > 1 ? g : nil
        }
    }

    func count(_ category: CleanupCategory) -> Int {
        let skip = ignoredPaths(category)
        if category == .duplicates { return duplicateGroups.reduce(0) { $0 + $1.photos.count } }
        return found(category).filter { !skip.contains($0.path) }.count
    }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    func loadIgnored(root: URL) {
        self.root = root
        ignored = CleanupIgnoreList.load(root: root)
    }

    /// Hides the selected photos from this category (or brings them back when showing ignored ones).
    func toggleIgnoreSelection(in category: CleanupCategory) throws {
        guard let root else { return }
        let visible = Set(photos(in: category).map(\.path))
        let chosen = selection.intersection(visible)
        guard !chosen.isEmpty else { return }
        var set = ignoredPaths(category)
        if showingIgnored { set.subtract(chosen) } else { set.formUnion(chosen) }
        ignored.categories[category.rawValue] = set.isEmpty ? nil : set
        selection.subtract(chosen)
        if showingIgnored && ignoredCount(category) == 0 { showingIgnored = false }
        try ignored.save(root: root)
    }

    func scan(_ photos: [IndexedPhoto], root: URL) {
        task?.cancel()
        loadIgnored(root: root)
        candidates = photos
        total = 0
        analyzed = 0
        isScanning = true
        selection.removeAll()
        task = Task {
            let store = PhotoAnalysisStore.shared
            // Only new or changed photos are analyzed; the rest comes from the cache.
            await store.ensureAnalyzed(photos, root: root) { [weak self] done, total in
                self?.analyzed = done
                self?.total = total
            }
            guard !Task.isCancelled else { return }
            var analyses: [String: PhotoFeatures] = [:]
            for photo in photos { if let f = store.features(for: photo) { analyses[photo.path] = f } }
            await classify(photos, analyses: analyses, root: root)
            isScanning = false
            hasResults = true
        }
    }

    private func classify(_ photos: [IndexedPhoto], analyses: [String: PhotoFeatures], root: URL) async {
        func label(_ photo: IndexedPhoto, _ names: [String]) -> Float {
            names.map { analyses[photo.path]?.labels[$0] ?? 0 }.max() ?? 0
        }
        func isScreenshot(_ p: IndexedPhoto) -> Bool {
            let name = p.name.lowercased()
            if name.contains("screenshot") || name.contains("screen shot") || name.contains("capture d") { return true }
            if p.userComment?.lowercased() == "screenshot" { return true }
            let noCamera = p.make == nil && p.model == nil
            return noCamera && (p.type == .png || label(p, ["screenshot"]) > 0.5)
        }
        screenshots = photos.filter(isScreenshot)
        let shots = Set(screenshots.map(\.path))
        screens = photos.filter { !shots.contains($0.path) && label($0, CleanupAnalyzer.screenLabels) > 0.3 }
        documents = photos.filter { !shots.contains($0.path) && label($0, CleanupAnalyzer.documentLabels) > 0.45 }
        sharpness = analyses.mapValues(\.sharpness)

        // Duplicates: exact (same bytes) and near-identical shots taken close together.
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var x = x
            while let p = parent[x], p != x { x = p }
            return x
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        for p in photos { parent[p.path] = p.path }

        let sameSize = Dictionary(grouping: photos, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
        if !sameSize.isEmpty {
            let hashes = await PhotoAnalysisStore.shared.fileHashes(sameSize, root: root)
            let byHash = Dictionary(grouping: hashes.map { ($0.key, $0.value) }, by: \.1)
            for same in byHash.values where same.count > 1 {
                for other in same.dropFirst() { union(same[0].0, other.0) }
            }
        }
        var prints: [String: [Float]] = [:]
        for (path, f) in analyses { if let data = f.scenePrint { prints[path] = data.floats } }
        let ordered = photos.sorted { $0.date < $1.date }
        for (i, a) in ordered.enumerated() {
            guard let aa = analyses[a.path] else { continue }
            for b in ordered[(i + 1)..<min(ordered.count, i + 12)] {
                guard abs(b.date.timeIntervalSince(a.date)) < 15 * 60, let bb = analyses[b.path] else { continue }
                if CleanupAnalyzer.areSimilar(aa, prints[a.path], bb, prints[b.path]) { union(a.path, b.path) }
            }
        }
        let groups = Dictionary(grouping: photos) { find($0.path) }.values.filter { $0.count > 1 }
        allDuplicateGroups = groups.map { members in
            let best = members.max { a, b in
                if a.pixelCount != b.pixelCount { return a.pixelCount < b.pixelCount }
                let sa = sharpness[a.path] ?? 0, sb = sharpness[b.path] ?? 0
                if sa != sb { return sa < sb }
                return a.size < b.size
            }
            return Group(photos: members.sorted { $0.date < $1.date }, keep: best?.path)
        }
        .sorted { ($0.photos.first?.date ?? .distantPast) > ($1.photos.first?.date ?? .distantPast) }
    }

    /// Default selection for a category: everything except the photo kept in each duplicate group.
    func selectSuggested(_ category: CleanupCategory) {
        if category == .duplicates && !showingIgnored {
            for group in duplicateGroups {
                for photo in group.photos where photo.path != group.keep { selection.insert(photo.path) }
            }
        } else {
            selection.formUnion(photos(in: category).map(\.path))
        }
    }

    func removeDeleted(_ paths: Set<String>) {
        screenshots.removeAll { paths.contains($0.path) }
        screens.removeAll { paths.contains($0.path) }
        documents.removeAll { paths.contains($0.path) }
        candidates.removeAll { paths.contains($0.path) }
        allDuplicateGroups = allDuplicateGroups.compactMap { group in
            var g = group
            g.photos.removeAll { paths.contains($0.path) }
            return g.photos.count > 1 ? g : nil
        }
        selection.subtract(paths)
    }
}

/// "Find photos to delete": scans a folder and its subfolders for cleanup candidates.
struct CleanupView: View {
    let folderURL: URL
    let title: String

    @Environment(FolderStore.self) private var folderStore
    @Environment(\.dismiss) private var dismiss
    @State private var index = PhotoIndex.shared
    @State private var model = CleanupModel()
    @State private var category: CleanupCategory = .screenshots
    @State private var deleting = false
    @State private var viewer: ViewerContext?
    @State private var error: String?
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 180

    private var root: URL? { folderStore.rootURL }

    private var scope: [IndexedPhoto] {
        guard let root else { return [] }
        let rootPath = root.standardizedFileURL.path
        var folder = folderURL.standardizedFileURL.path
        if folder.hasPrefix(rootPath) { folder = String(folder.dropFirst(rootPath.count)) }
        folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return index.photos.filter { folder.isEmpty || $0.path.hasPrefix(folder + "/") }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isScanning || index.isScanning {
                    progress
                } else if !model.hasResults {
                    intro
                } else {
                    results
                }
            }
            .navigationTitle("Find Photos to Delete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.cancel(); dismiss() }
                }
                if model.hasResults && !model.isScanning {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Scan Again", systemImage: "arrow.clockwise") { startScan() }
                    }
                }
            }
        }
        .task {
            if let root {
                index.refreshIfNeeded(root: root)
                model.loadIgnored(root: root)
            }
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(context: $0) }
        .alert("Something Went Wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private var intro: some View {
        ContentUnavailableView {
            Label("Find Photos to Delete", systemImage: "sparkle.magnifyingglass")
        } description: {
            Text("Looks through \(scope.count) photos in \(title) and its subfolders for screenshots, photos of screens, documents, duplicates and blurry shots. Everything is analyzed on this iPad, and the results are remembered: the next scan only analyzes new or changed photos.")
        } actions: {
            Button("Scan Photos") { startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(scope.isEmpty)
        }
    }

    private var progress: some View {
        VStack(spacing: 14) {
            if index.isScanning {
                ProgressView(value: Double(index.scanned), total: Double(max(1, index.toScan)))
                    .frame(maxWidth: 360)
                Text("Reading photo details… \(index.scanned) of \(index.toScan)").foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(model.analyzed), total: Double(max(1, model.total)))
                    .frame(maxWidth: 360)
                Text(model.total == 0 ? "Comparing photos…" : "Analyzing \(model.analyzed) of \(model.total) new or changed photos…")
                    .monospacedDigit()
                Button("Stop", role: .destructive) { model.cancel() }.buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private func startScan() {
        guard let root else { return }
        Task {
            index.refresh(root: root)
            while index.isScanning { try? await Task.sleep(for: .milliseconds(200)) }
            model.scan(scope, root: root)
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CleanupCategory.allCases) { c in
                        Button {
                            category = c
                            model.showingIgnored = false
                        } label: {
                            Label("\(c.title) · \(model.count(c))", systemImage: c.systemImage)
                                .font(.callout.weight(category == c ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(category == c ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                                            in: Capsule())
                                .foregroundStyle(category == c ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal).padding(.vertical, 10)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.showingIgnored ? "Ignored photos are hidden from \(category.title). Select some and tap Stop Ignoring to bring them back."
                             : category.explanation)
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        let ignoredCount = model.ignoredCount(category)
                        if ignoredCount > 0 || model.showingIgnored {
                            Button(model.showingIgnored ? "Done" : "Show \(ignoredCount) Ignored") {
                                model.selection.removeAll()
                                model.showingIgnored.toggle()
                            }
                            .font(.callout)
                        }
                    }
                    if category == .blurry && !model.showingIgnored {
                        HStack {
                            Text("Fewer")
                            Slider(value: $model.blurThreshold, in: 5...200)
                            Text("More")
                        }
                        .font(.caption)
                    }
                    let photos = model.photos(in: category)
                    if photos.isEmpty {
                        ContentUnavailableView(model.showingIgnored ? "Nothing Ignored" : "Nothing Found",
                                               systemImage: "checkmark.circle")
                    } else if category == .duplicates && !model.showingIgnored {
                        ForEach(model.duplicateGroups) { group in
                            grid(group.photos, keep: group.keep)
                            Divider()
                        }
                    } else {
                        grid(photos, keep: nil)
                    }
                }
                .padding()
            }
            Divider()
            CleanupBottomBar(model: model, category: category, deleting: deleting,
                             onDelete: deleteSelected, onError: { error = $0 })
        }
    }

    private func grid(_ photos: [IndexedPhoto], keep: String?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: max(110, thumbnailSize * 0.8)), spacing: 4)], spacing: 4) {
            ForEach(photos) { photo in
                if let root {
                    CleanupCell(photo: photo, keep: keep, model: model, root: root) {
                        viewer = ViewerContext(items: photos.map { $0.libraryItem(root: root) },
                                               startURL: photo.url(root: root))
                    }
                }
            }
        }
    }

    private func deleteSelected() {
        guard let root else { return }
        deleting = true
        let paths = model.selection
        let urls = paths.map { root.appendingPathComponent($0) }
        Task {
            let failures = await Task.detached(priority: .userInitiated) { PhotoDeletion.delete(urls) }.value
            let failed = Set(failures.map(\.name))
            model.removeDeleted(paths.filter { !failed.contains(($0 as NSString).lastPathComponent) })
            deleting = false
            index.refresh(root: root)
            if !failures.isEmpty {
                error = failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")
            }
        }
    }
}

/// One selectable thumbnail. It reads the selection itself, so toggling one photo redraws only
/// this cell, not the whole list (which made the scroll position jump).
private struct CleanupCell: View {
    let photo: IndexedPhoto
    let keep: String?
    let model: CleanupModel
    let root: URL
    let onView: () -> Void

    var body: some View {
        let selected = model.selection.contains(photo.path)
        Button {
            if selected { model.selection.remove(photo.path) } else { model.selection.insert(photo.path) }
        } label: {
            ThumbnailCell(item: photo.libraryItem(root: root), pixelSize: 300)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.red : Color.black.opacity(0.3))
                        .shadow(radius: 2)
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if photo.path == keep {
                        Text("KEEP").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.green, in: Capsule()).foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay { if selected { Rectangle().stroke(Color.red, lineWidth: 3) } }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("View", systemImage: "eye", action: onView)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CleanupBottomBar: View {
    let model: CleanupModel
    let category: CleanupCategory
    let deleting: Bool
    let onDelete: () -> Void
    let onError: (String) -> Void
    @State private var confirmDelete = false

    private var deleteTitle: String {
        model.selection.count == 1 ? "Delete 1 Photo" : "Delete \(model.selection.count) Photos"
    }

    var body: some View {
        let inCategory = Set(model.photos(in: category).map(\.path))
        HStack {
            Text("\(model.selection.count) selected").font(.headline).monospacedDigit()
            Spacer()
            Button("Select Suggested") { model.selectSuggested(category) }
                .disabled(inCategory.isEmpty)
            Button("Deselect All") { model.selection.removeAll() }
                .disabled(model.selection.isEmpty)
            Button(model.showingIgnored ? "Stop Ignoring" : "Ignore",
                   systemImage: model.showingIgnored ? "eye" : "eye.slash") {
                do { try model.toggleIgnoreSelection(in: category) } catch { onError(error.localizedDescription) }
            }
            .disabled(model.selection.intersection(inCategory).isEmpty)
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.selection.isEmpty || deleting)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deleteTitle, role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are removed from the folder, and Synctrain will remove them from your other devices too. This can't be undone in SyncDarkroom.")
        }
    }
}
