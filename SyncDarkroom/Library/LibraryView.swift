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
    @State private var isPasting = false
    @State private var libraryError: String?
    @State private var selecting = false
    @State private var selection: Set<URL> = []
    @State private var batch: BatchContext?

    @AppStorage("sortOrder") private var sortOrder: SortOrder = .dateNewest
    @AppStorage("typeFilter") private var typeFilter: TypeFilter = .all
    @AppStorage("hideEditedCopies") private var hideEditedCopies = false
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 180
    @AppStorage("exportFormat") private var exportFormat: ExportFormat = .jpeg
    @AppStorage("exportQuality") private var exportQuality: Double = 0.9

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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 4)], spacing: 4) {
                        ForEach(photos) { photo in
                            Button {
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
                            .contextMenu {
                                Button("Edit", systemImage: "slider.horizontal.3") { editing = photo }
                                Button("View", systemImage: "eye") {
                                    viewer = ViewerContext(items: photos, startURL: photo.url)
                                }
                                Divider()
                                if photo.isEditedCopy {
                                    Button("Copy Edit Settings", systemImage: "doc.on.doc") { copySettings(from: photo) }
                                }
                                if SettingsClipboard.look != nil {
                                    Button("Paste Settings as New Copy", systemImage: "doc.on.clipboard") {
                                        pasteSettings(onto: photo)
                                    }
                                }
                            }
                        }
                    }
                    Text(summary(photos: photos))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding()
        }
        .overlay { emptyState(folders: folders, photos: photos) }
        .overlay {
            if isPasting {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Saving new copy…").font(.callout)
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

    private func selectionBar(photos: [LibraryItem]) -> some View {
        let chosen = photos.filter { selection.contains($0.url) }
        return HStack(spacing: 16) {
            Text(chosen.isEmpty ? "Select photos" : "\(chosen.count) selected")
                .font(.headline)
                .monospacedDigit()
            Spacer()
            Button("Paste Settings", systemImage: "doc.on.clipboard") {
                batch = BatchContext(items: chosen, initialChoice: .copied)
            }
            .disabled(chosen.isEmpty || SettingsClipboard.look == nil)
            Button("Apply Preset…", systemImage: "square.stack.3d.down.right") {
                batch = BatchContext(items: chosen, initialChoice: nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
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

            if isRoot {
                Menu {
                    Button("Choose Another Folder…", systemImage: "folder.badge.gearshape") {
                        showPicker = true
                    }
                    Button("Forget Folder", systemImage: "xmark.circle", role: .destructive) {
                        folderStore.forget()
                    }
                } label: {
                    Label("Folder", systemImage: "folder")
                }
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

    /// Applies the copied look (not the crop) to the photo's original and saves a new copy.
    private func pasteSettings(onto item: LibraryItem) {
        guard let look = SettingsClipboard.look, !isPasting else { return }
        isPasting = true
        let format = exportFormat, quality = exportQuality
        Task {
            defer { isPasting = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let plan = BatchEdit.plan(for: item, look: look)
                    _ = try ExportJob(source: plan.source, recipe: plan.recipe, format: format,
                                      quality: quality, updating: nil).run()
                }.value
                await model.load()
            } catch {
                libraryError = error.localizedDescription
            }
        }
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
