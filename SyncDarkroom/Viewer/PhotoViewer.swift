import CoreImage
import SwiftUI

struct ViewerContext: Identifiable {
    let id = UUID()
    let items: [LibraryItem]
    let startURL: URL
}

struct PhotoViewer: View {
    let context: ViewerContext

    @Environment(\.dismiss) private var dismiss
    @State private var selection: URL
    @State private var editing: LibraryItem?
    @State private var reloadToken = UUID()
    @State private var comparing = false
    @State private var items: [LibraryItem]
    @State private var confirmDelete = false
    @State private var deleteError: String?
    @State private var rotating = false
    @AppStorage("viewerShowsInfo") private var showsInfo = false

    init(context: ViewerContext) {
        self.context = context
        _selection = State(initialValue: context.startURL)
        _items = State(initialValue: context.items)
    }

    private var current: LibraryItem? {
        items.first { $0.url == selection }
    }

    private var positionText: String {
        guard let index = items.firstIndex(where: { $0.url == selection }) else { return "" }
        return "\(index + 1) of \(items.count)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if comparing, let current {
                    // Shown instead of the pager so dragging the divider doesn't flip photos.
                    CopyComparePage(item: current, reloadToken: reloadToken)
                } else {
                    TabView(selection: $selection) {
                        ForEach(items) { item in
                            PhotoPage(item: item, reloadToken: reloadToken)
                                .tag(item.url)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(current?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(current?.name ?? "").font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(positionText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if current?.isEditedCopy == true {
                        Button("Compare with Original",
                               systemImage: comparing ? "square.split.2x1.fill" : "square.split.2x1") {
                            comparing.toggle()
                        }
                        .keyboardShortcut("y", modifiers: .command)
                    }
                    Button("Rotate 90° Clockwise", systemImage: "rotate.right") { rotateCurrent() }
                        .disabled(current == nil || rotating)
                        .keyboardShortcut("r", modifiers: .command)
                    Button("Edit", systemImage: "slider.horizontal.3") { editing = current }
                        .keyboardShortcut("e", modifiers: .command)
                    ShareButton(urls: current.map { [$0.url] } ?? [], iconOnly: true)
                    Button("Delete", systemImage: "trash") { confirmDelete = true }
                        .disabled(current == nil)
                        .keyboardShortcut(.delete, modifiers: .command)
                    Button("Info", systemImage: showsInfo ? "info.circle.fill" : "info.circle") {
                        showsInfo.toggle()
                    }
                    .keyboardShortcut("i", modifiers: .command)
                }
            }
            .inspector(isPresented: $showsInfo) {
                if let current {
                    MetadataPanel(item: current)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $editing) { item in
            EditorView(item: item) { reloadToken = UUID() }
        }
        .onChange(of: selection) { comparing = false }
        .confirmationDialog("Delete \(current?.name ?? "this photo")?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from this folder, and Synctrain will remove it from your other devices too. This can't be undone in SyncDarkroom.")
        }
        .overlay {
            if rotating { ProgressView().controlSize(.large).tint(.white) }
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func rotateCurrent() {
        guard let item = current else { return }
        rotating = true
        let url = item.url
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try PhotoRotation.rotateClockwise(url) }.value
                // Pick up the new file date so this page and the thumbnails reload.
                if let i = items.firstIndex(of: item),
                   let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    items[i] = LibraryItem(url: item.url, name: item.name, isFolder: false, type: item.type,
                                           modified: item.isEditedCopy ? item.modified.addingTimeInterval(0.001) : date,
                                           fileSize: item.fileSize, hasEdits: item.hasEdits)
                }
                reloadToken = UUID()
            } catch {
                deleteError = error.localizedDescription
            }
            rotating = false
        }
    }

    private func deleteCurrent() {
        guard let item = current, let index = items.firstIndex(of: item) else { return }
        let url = item.url
        Task {
            let failures = await Task.detached(priority: .userInitiated) { PhotoDeletion.delete([url]) }.value
            if let failure = failures.first {
                deleteError = failure.message
                return
            }
            items.remove(at: index)
            if items.isEmpty {
                dismiss()
            } else {
                // Show the next photo (or the previous one if this was the last).
                selection = items[min(index, items.count - 1)].url
            }
        }
    }
}

/// An edited copy next to its original, rendered with the same crop so the split lines up.
private struct CopyComparePage: View {
    let item: LibraryItem
    let reloadToken: UUID

    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var message: String?

    var body: some View {
        ZStack {
            Color.black
            if let before, let after {
                SplitCompareView(before: before, after: after).padding(16)
            } else if let message {
                ContentUnavailableView("Can't Compare", systemImage: "square.split.2x1", description: Text(message))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: "\(item.url)\(reloadToken)") {
            let url = item.url
            let result = await Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?, String?) in
                guard let sidecar = SidecarStore.load(forCopy: url) else {
                    return (nil, nil, "This copy wasn't made by SyncDarkroom, so its original isn't known.")
                }
                let original = url.deletingLastPathComponent().appendingPathComponent(sidecar.source)
                let ci: CIImage
                let scale: CGFloat
                if RawDecoder.isRaw(original) {
                    guard let raw = RawDecoder.preview(url: original, settings: nil) else {
                        return (nil, nil, "The RAW original \(sidecar.source) couldn't be decoded.")
                    }
                    ci = raw.image
                    scale = ci.extent.width / raw.fullSize.width
                } else {
                    guard let source = ImageLoading.downsampled(url: original, maxPixelSize: 2048),
                          let cg = source.cgImage else {
                        return (nil, nil, "The original \(sidecar.source) isn't available.")
                    }
                    ci = CIImage(cgImage: cg)
                    scale = PhotoMetadata.read(from: original).pixelWidth.map { ci.extent.width / CGFloat($0) } ?? 1
                }
                let before = Renderer.makeUIImage(Renderer.render(ci, recipe: sidecar.recipe.geometryOnly, scale: scale))
                let after = ImageLoading.downsampled(url: url, maxPixelSize: 2048)
                return (before, after, nil)
            }.value
            if Task.isCancelled { return }
            (before, after, message) = result
        }
    }
}

private struct PhotoPage: View {
    let item: LibraryItem
    let reloadToken: UUID

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImageView(image: image)
            } else if failed {
                ContentUnavailableView("Can't Open Photo", systemImage: "photo.badge.exclamationmark",
                                       description: Text(item.name))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: "\(item.modified)\(reloadToken)") {
            let url = item.url
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoading.downsampled(url: url, maxPixelSize: 4096)
            }.value
            if Task.isCancelled { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// Pinch / double-tap zoomable image backed by UIScrollView.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.image = image
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var configuredSize: CGSize = .zero

    var image: UIImage? {
        didSet {
            imageView.image = image
            configuredSize = .zero
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != configuredSize {
            configuredSize = bounds.size
            configureForCurrentSize()
        }
        centerImage()
    }

    private func configureForCurrentSize() {
        guard let image, bounds.width > 0, bounds.height > 0 else { return }
        zoomScale = 1
        let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * fitScale, height: image.size.height * fitScale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        minimumZoomScale = 1
        let pixelWidth = image.size.width * image.scale
        maximumZoomScale = max(4, pixelWidth / fitted.width * 2)
    }

    private func centerImage() {
        imageView.center = CGPoint(
            x: max(contentSize.width, bounds.width) / 2,
            y: max(contentSize.height, bounds.height) / 2
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 3)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
