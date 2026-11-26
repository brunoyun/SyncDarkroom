import SwiftUI

struct LibraryView: View {
    let folderURL: URL
    var isRoot = false

    @Environment(FolderStore.self) private var folderStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: FolderModel
    @State private var viewer: ViewerContext?
    @State private var editing: LibraryItem?
    @State private var showPicker = false
    @State private var libraryError: String?
    @State private var selecting = false
    @State private var selection: Set<URL> = []
    @State private var batch: BatchContext?
    @State private var metrics = ScrollMetrics()
    @State private var dragSelect: DragSelectState?
    @State private var dragSelectStarts = 0
    @State private var tapBlockedUntil = Date.distantPast
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var pendingDelete: [LibraryItem]?
    @State private var isDeleting = false
    @State private var showStats = false
    @State private var showCleanup = false

    private let gridSpacing: CGFloat = 4

    /// Long-press-and-drag selection in progress.
    private struct DragSelectState {
        var anchor: Int
        var adding: Bool
        var base: Set<URL>
        var gridX: CGFloat
        var viewportY: CGFloat
    }

    @AppStorage("sortOrder") private var sortOrder: SortOrder = .dateNewest
    @AppStorage("typeFilter") private var typeFilter: TypeFilter = .all
    @AppStorage("hideEditedCopies") private var hideEditedCopies = false
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 180

    init(folderURL: URL, isRoot: Bool = false) {
        self.folderURL = folderURL
        self.isRoot = isRoot
        _model = State(initialValue: FolderModel(url: folderURL))
    }

    private var folders: [LibraryItem] {
        model.items.filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var photos: [LibraryItem] {
        sortOrder.sorted(model.items.filter { item in
            !item.isFolder
                && typeFilter.matches(item.type)
                && !(hideEditedCopies && item.isEditedCopy)
        })
    }

    var body: some View {
        let folders = folders
        let photos = photos

        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !folders.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(folders) { folder in
                            NavigationLink(value: folder.url) {
                                FolderCell(item: folder)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !photos.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: gridSpacing)],
                              spacing: gridSpacing) {
                        ForEach(photos) { photo in
                            Button {
                                // The release of a long press must not also count as a tap.
                                guard dragSelect == nil, Date() > tapBlockedUntil else { return }
                                if selecting {
                                    if selection.contains(photo.url) { selection.remove(photo.url) } else { selection.insert(photo.url) }
                                } else {
                                    viewer = ViewerContext(items: photos, startURL: photo.url)
                                }
                            } label: {
                                ThumbnailCell(item: photo, pixelSize: Int(thumbnailSize * 2))
                                    .overlay(alignment: .topTrailing) {
                                        if selecting { SelectionMark(selected: selection.contains(photo.url)) }
                                    }
                                    .overlay {
                                        if selecting && selection.contains(photo.url) {
                                            Rectangle().stroke(Color.accentColor, lineWidth: 3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selecting && selection.contains(photo.url) ? .isSelected : [])
                            .accessibilityHint(selecting ? "Toggles selection" : "Opens the photo. Touch and hold to select.")
                            .id(photo.url)
                        }
                    }
                    .coordinateSpace(name: "photoGrid")
                    .background {
                        LongPressDragProbe(
                            onBegan: { dragSelect(at: $0, photos: photos, proxy: proxy) },
                            onChanged: { dragSelect(at: $0, photos: photos, proxy: proxy) },
                            onEnded: { endDragSelect() }
                        )
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("viewport")) } action: { frame in
                        metrics.gridMinY = frame.minY
                        metrics.gridWidth = frame.width
                    }
                    Text(summary(photos: photos))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("viewport")) } action: { frame in
                metrics.contentMinY = frame.minY
                metrics.contentHeight = frame.height
            }
        }
        .coordinateSpace(name: "viewport")
        .scrollIndicators(.hidden)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
            metrics.topInset = insets.top
            metrics.bottomInset = insets.bottom
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { metrics.viewportHeight = $0 }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            // A column of its own (not an overlay) so its drags aren't taken by the scroll view.
            FastScrubber(metrics: metrics, photos: photos, sortOrder: sortOrder) { index in
                proxy.scrollTo(photos[index].url, anchor: .top)
            }
        }
        }
        .sensoryFeedback(.selection, trigger: dragSelectStarts)
        .overlay { emptyState(folders: folders, photos: photos) }
        .overlay {
            if isDeleting {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Deleting…").font(.callout)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { libraryError != nil }, set: { if !$0 { libraryError = nil } })) {
            Button("OK") {}
        } message: {
            Text(libraryError ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar(photos: photos) }
        }
        .sheet(item: $batch, onDismiss: {
            Task { await model.load() }
        }) { context in
            BatchView(context: context) {
                selecting = false
                selection.removeAll()
            }
        }
        .onChange(of: selecting) { if !selecting { selection.removeAll() } }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                              set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(deleteTitle, role: .destructive) {
                if let items = pendingDelete { delete(items) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are removed from this folder, and Synctrain will remove them from your other devices too. This can't be undone in SyncDarkroom.")
        }
        .refreshable { await model.load() }
        .navigationTitle(isRoot ? folderStore.displayName : folderURL.lastPathComponent)
        .toolbar { toolbarContent }
        .task {
            await model.load()
            model.startWatching()
            #if DEBUG
            // Simulator testing: launch with `-debugEditFile <name>` to open the editor directly.
            if isRoot, let name = UserDefaults.standard.string(forKey: "debugEditFile"),
               let item = model.items.first(where: { $0.name == name }), editing == nil {
                editing = item
            }
            #endif
        }
        .onDisappear { model.stopWatching() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .fullScreenCover(item: $viewer) { context in
            PhotoViewer(context: context)
        }
        .fullScreenCover(item: $editing) { item in
            EditorView(item: item) { Task { await model.load() } }
        }
        .folderPicker(isPresented: $showPicker)
        .sheet(isPresented: $showStats) {
            FolderStatsView(folderURL: folderURL, title: navigationTitle)
        }
        .sheet(isPresented: $showCleanup, onDismiss: { Task { await model.load() } }) {
            CleanupView(folderURL: folderURL, title: navigationTitle)
        }
    }

    private var navigationTitle: String {
        isRoot ? folderStore.displayName : folderURL.lastPathComponent
    }

    @ViewBuilder
    private func emptyState(folders: [LibraryItem], photos: [LibraryItem]) -> some View {
        if !model.hasLoaded {
            ProgressView()
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Can't Read Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Choose Folder Again") { showPicker = true }
            }
        } else if folders.isEmpty && photos.isEmpty {
            if model.items.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Photos synced into this folder will appear here automatically."))
            } else {
                ContentUnavailableView("No Matching Photos", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Change the filter to see more."))
            }
        }
    }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return n == 1 ? "Delete 1 Photo" : "Delete \(n) Photos"
    }

    private func selectionBar(photos: [LibraryItem]) -> some View {
        let chosen = photos.filter { selection.contains($0.url) }
        let single = chosen.count == 1 ? chosen.first : nil
        return HStack(spacing: 14) {
            Text(chosen.isEmpty ? "Select photos" : "\(chosen.count) selected")
                .font(.headline)
                .monospacedDigit()
            Spacer()
            if let single {
                Button("Edit", systemImage: "slider.horizontal.3") { editing = single }
                if single.isEditedCopy {
                    Button("Copy Settings", systemImage: "doc.on.doc") { copySettings(from: single) }
                }
            }
            Button("Paste Settings", systemImage: "doc.on.clipboard") {
                batch = BatchContext(items: chosen, initialChoice: .copied)
            }
            .disabled(chosen.isEmpty || SettingsClipboard.look == nil)
            Button("Apply Preset…", systemImage: "square.stack.3d.down.right") {
                batch = BatchContext(items: chosen, initialChoice: nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
            ShareButton(urls: chosen.map(\.url), iconOnly: true)
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = chosen }
                .labelStyle(.iconOnly)
                .disabled(chosen.isEmpty)
                .accessibilityLabel("Delete selected photos")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if selecting {
                let all = photos.map(\.url)
                let allSelected = !all.isEmpty && Set(all).isSubset(of: selection)
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { selection.removeAll() } else { selection.formUnion(all) }
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(selecting ? "Done" : "Select") { selecting.toggle() }
                .fontWeight(selecting ? .semibold : .regular)
                .disabled(photos.isEmpty && !selecting)

            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                Picker("Show", selection: $typeFilter) {
                    ForEach(TypeFilter.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Hide Edited Copies", isOn: $hideEditedCopies)
                Section("Thumbnail Size") {
                    Button("Smaller", systemImage: "minus.magnifyingglass") {
                        thumbnailSize = max(100, thumbnailSize - 40)
                    }
                    .disabled(thumbnailSize <= 100)
                    Button("Larger", systemImage: "plus.magnifyingglass") {
                        thumbnailSize = min(380, thumbnailSize + 40)
                    }
                    .disabled(thumbnailSize >= 380)
                }
            } label: {
                Label("View Options", systemImage: typeFilter == .all && !hideEditedCopies
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }

            Menu {
                Button("Statistics", systemImage: "chart.bar.xaxis") { showStats = true }
                Button("Find Photos to Delete…", systemImage: "sparkle.magnifyingglass") { showCleanup = true }
                if isRoot {
                    Divider()
                    Button("Choose Another Folder…", systemImage: "folder.badge.gearshape") {
                        showPicker = true
                    }
                    Button("Forget Folder", systemImage: "xmark.circle", role: .destructive) {
                        folderStore.forget()
                    }
                }
            } label: {
                Label("Folder", systemImage: "folder")
            }
        }
    }

    // MARK: Drag selection

    private func endDragSelect() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        if dragSelect != nil { tapBlockedUntil = Date().addingTimeInterval(0.4) }
        dragSelect = nil
    }

    /// Columns and row pitch of the adaptive photo grid (rows are square).
    private func gridLayout() -> (columns: Int, pitch: CGFloat) {
        let width = max(1, metrics.gridWidth)
        let columns = max(1, Int((width + gridSpacing) / (CGFloat(thumbnailSize) + gridSpacing)))
        let cell = (width - CGFloat(columns - 1) * gridSpacing) / CGFloat(columns)
        return (columns, cell + gridSpacing)
    }

    private func photoIndex(at point: CGPoint, count: Int) -> Int {
        let (columns, pitch) = gridLayout()
        let column = min(columns - 1, max(0, Int(point.x / pitch)))
        let row = max(0, Int(floor(point.y / pitch)))
        return min(count - 1, max(0, row * columns + column))
    }

    private func dragSelect(at location: CGPoint, photos: [LibraryItem], proxy: ScrollViewProxy) {
        guard !photos.isEmpty else { return }
        let index = photoIndex(at: location, count: photos.count)
        if dragSelect == nil {
            if !selecting { selecting = true }
            let adding = !selection.contains(photos[index].url)
            dragSelect = DragSelectState(anchor: index, adding: adding, base: selection,
                                         gridX: location.x, viewportY: location.y + metrics.gridMinY)
            dragSelectStarts += 1
        }
        dragSelect?.gridX = location.x
        dragSelect?.viewportY = location.y + metrics.gridMinY
        applyDragSelection(to: index, photos: photos)
        updateAutoScroll(photos: photos, proxy: proxy)
    }

    /// Selects (or deselects) everything between the first photo and the one under the finger.
    private func applyDragSelection(to index: Int, photos: [LibraryItem]) {
        guard let state = dragSelect else { return }
        let range = min(state.anchor, index)...max(state.anchor, index)
        let urls = photos[range].map(\.url)
        selection = state.adding ? state.base.union(urls) : state.base.subtracting(urls)
    }

    private func autoScrollDirection() -> Int {
        guard let y = dragSelect?.viewportY else { return 0 }
        if y > metrics.viewportHeight - metrics.bottomInset - 70 { return 1 }
        if y < metrics.topInset + 70 { return -1 }
        return 0
    }

    /// Scrolls while the finger rests near the top or bottom edge, extending the selection.
    private func updateAutoScroll(photos: [LibraryItem], proxy: ScrollViewProxy) {
        guard autoScrollDirection() != 0 else {
            autoScrollTask?.cancel()
            autoScrollTask = nil
            return
        }
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled, dragSelect != nil {
                let direction = autoScrollDirection()
                if direction == 0 { break }
                let (columns, pitch) = gridLayout()
                if direction > 0 {
                    let bottomRow = Int((metrics.viewportHeight - metrics.bottomInset - metrics.gridMinY) / pitch)
                    let target = min(photos.count - 1, (bottomRow + 1) * columns)
                    withAnimation(.linear(duration: 0.12)) { proxy.scrollTo(photos[target].url, anchor: .bottom) }
                } else {
                    let topRow = Int((metrics.topInset - metrics.gridMinY) / pitch)
                    let target = max(0, (topRow - 1) * columns)
                    withAnimation(.linear(duration: 0.12)) { proxy.scrollTo(photos[target].url, anchor: .top) }
                }
                try? await Task.sleep(for: .milliseconds(130))
                // The content moved under a resting finger: re-pick the photo beneath it.
                if let state = dragSelect {
                    let point = CGPoint(x: state.gridX, y: state.viewportY - metrics.gridMinY)
                    applyDragSelection(to: photoIndex(at: point, count: photos.count), photos: photos)
                }
            }
            autoScrollTask = nil
        }
    }

    // MARK: Actions

    private func delete(_ items: [LibraryItem]) {
        isDeleting = true
        let urls = items.map(\.url)
        Task {
            let failures = await Task.detached(priority: .userInitiated) { PhotoDeletion.delete(urls) }.value
            isDeleting = false
            selection.subtract(urls)
            if selection.isEmpty { selecting = false }
            await model.load()
            if !failures.isEmpty {
                libraryError = "Couldn't delete " + failures.map { "\($0.name) (\($0.message))" }.joined(separator: ", ")
            }
        }
    }

    private func copySettings(from copy: LibraryItem) {
        guard let sidecar = SidecarStore.load(forCopy: copy.url) else {
            libraryError = "\(copy.name) wasn't made by SyncDarkroom, so it has no settings to copy."
            return
        }
        SettingsClipboard.look = sidecar.recipe.look
    }

    private func summary(photos: [LibraryItem]) -> String {
        let total = photos.reduce(Int64(0)) { $0 + $1.fileSize }
        let count = photos.count == 1 ? "1 photo" : "\(photos.count) photos"
        return "\(count) · \(total.formatted(.byteCount(style: .file)))"
    }
}

struct FolderCell: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

struct ThumbnailCell: View {
    let item: LibraryItem
    let pixelSize: Int

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) { badges }
            .contentShape(Rectangle())
            .accessibilityLabel(item.name)
            .task(id: "\(item.id)|\(pixelSize)|\(item.modified)") {
                let loaded = await ThumbnailLoader.shared.image(for: item, maxPixelSize: pixelSize)
                if Task.isCancelled { return }
                image = loaded
                failed = loaded == nil
            }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if item.type == .raw { Badge(text: "RAW") }
            if item.isEditedCopy { Badge(text: "EDIT") }
            if item.hasEdits { Badge(text: "", systemImage: "slider.horizontal.3") }
        }
        .padding(5)
    }
}

private struct Badge: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 2) {
            if let systemImage { Image(systemName: systemImage) }
            if !text.isEmpty { Text(text) }
        }
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.white)
    }
}

private struct SelectionMark: View {
    let selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.3))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(6)
    }
}
