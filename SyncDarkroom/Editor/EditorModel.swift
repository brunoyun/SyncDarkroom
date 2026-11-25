import CoreImage
import Observation
import UIKit

@MainActor
@Observable
final class EditorModel {
    enum Panel: String, CaseIterable, Identifiable {
        case presets, light, color, curves, detail, crop, masks, heal, markup
        var id: String { rawValue }
        var title: String {
            switch self {
            case .presets: "Presets"
            case .light: "Light"
            case .color: "Color"
            case .curves: "Curves"
            case .detail: "Detail"
            case .crop: "Crop"
            case .masks: "Masks"
            case .heal: "Heal"
            case .markup: "Markup"
            }
        }
        var systemImage: String {
            switch self {
            case .presets: "square.stack.3d.down.right"
            case .light: "sun.max"
            case .color: "paintpalette"
            case .curves: "point.topleft.down.to.point.bottomright.curvepath"
            case .detail: "camera.filters"
            case .crop: "crop.rotate"
            case .masks: "circle.lefthalf.filled.righthalf.striped.horizontal"
            case .heal: "bandage"
            case .markup: "pencil.tip.crop.circle"
            }
        }
    }

    enum CompareMode: String, CaseIterable, Identifiable {
        case off, split, sideBySide
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .split: "Split View"
            case .sideBySide: "Side by Side"
            }
        }
    }

    let item: LibraryItem
    private(set) var sourceURL: URL

    var recipe = EditRecipe() {
        didSet { if recipe != oldValue { requestRender() } }
    }
    var panel: Panel = .light {
        didSet {
            if Self.geometryMode(for: panel) != Self.geometryMode(for: oldValue)
                || (panel == .markup) != (oldValue == .markup) || panel == .masks || oldValue == .masks {
                requestRender()
            }
            if panel == .presets { renderPresetThumbnails() }
        }
    }
    /// Press-and-hold on the canvas: show the "before" image.
    var showOriginal = false {
        didSet { if showOriginal { requestRender() } }
    }
    var compareMode: CompareMode = .off {
        didSet { if compareMode != .off { requestRender() } }
    }

    /// Root of the synced folder; user presets are stored under it.
    var presetsRoot: URL?
    private(set) var userPresets: [Preset] = []
    private(set) var presetThumbnails: [UUID: UIImage] = [:]
    var hasCopiedSettings: Bool { SettingsClipboard.look != nil }

    private(set) var rendered: UIImage?
    /// Same crop/geometry as the edit but no tone/color changes, for before/after.
    private(set) var renderedBefore: UIImage?
    @ObservationIgnored private var renderedBeforeGeometry: Geometry?
    @ObservationIgnored private var thumbnailSource: CIImage?
    @ObservationIgnored private var thumbnailGeometry: Geometry?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    /// Geometry mode the current `rendered` image was made with.
    private(set) var renderedMode: Renderer.GeometryMode = .full
    var renderedIncludesCrop: Bool { renderedMode == .full }

    // Local-edit tool state.
    var selectedMaskID: UUID? { didSet { if selectedMaskID != oldValue { requestRender() } } }
    var showMaskOverlay = true { didSet { if showMaskOverlay != oldValue { requestRender() } } }
    var brushErase = false
    var brushSize = 0.06
    var brushSoftness = 0.6
    var brushFlow = 0.8
    var selectedHealID: UUID?
    var healMode: HealSpot.Mode = .heal
    var healSize = 0.04
    enum MarkupTool: String, CaseIterable, Identifiable {
        case draw, text, shapes
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    var markupTool: MarkupTool = .draw
    var shapeKind: ShapeItem.Kind = .arrow
    var markupColor = RGBAColor.red
    var shapeWidth = 0.006
    var textSize = 0.05
    var drawWithFinger = false

    static func geometryMode(for panel: Panel) -> Renderer.GeometryMode {
        switch panel {
        case .crop: .uncropped
        case .masks, .heal: .orientOnly
        default: .full
        }
    }
    private(set) var original: UIImage?
    private(set) var loadError: String?
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var savedRecipe = EditRecipe()
    /// The edited copy this session updates; nil while it's a new edit of the original.
    private(set) var editingCopy: URL?

    private var undoStack: [EditRecipe] = []
    private var redoStack: [EditRecipe] = []

    @ObservationIgnored private var previewSource: CIImage? {
        didSet {
            guard let source = previewSource else { return }
            let s = 220 / max(source.extent.width, source.extent.height)
            thumbnailSource = source.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
    }
    /// Low-res pixels of the original for choosing heal sources (built on first use).
    @ObservationIgnored private var sampler: PixelSampler?
    /// RAW only: the camera-default decode, used as "before".
    @ObservationIgnored private var defaultSource: CIImage?
    /// RAW only: the decoder settings `previewSource` was decoded with.
    @ObservationIgnored private var decodedRaw: RawSettings?
    /// Non-nil when the original is a RAW file; camera defaults and supported controls.
    private(set) var rawDefaults: RawDefaults?
    private(set) var isDecodingRaw = false
    var isRaw: Bool { rawDefaults != nil }
    @ObservationIgnored private var fullSize: CGSize = .zero
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var needsRender = false

    init(item: LibraryItem) {
        self.item = item
        self.sourceURL = item.url
    }

    var isDirty: Bool { recipe != savedRecipe }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// What Save will do, shown above the canvas.
    var saveDescription: String {
        if let editingCopy { return "Updating \(editingCopy.lastPathComponent)" }
        return "New edit of \(sourceURL.lastPathComponent) — saves as a new copy"
    }

    /// Size of the (oriented) original that masks and heal spots are relative to.
    var sourceSize: CGSize { previewSource?.extent.size ?? fullSize }

    /// Size of the straightened frame the crop rectangle is relative to.
    var baseSize: CGSize {
        Renderer.baseSize(for: previewSource?.extent.size ?? fullSize, geometry: recipe.geometry)
    }

    // MARK: Loading

    func load() async {
        guard !isLoaded else { return }
        let item = item
        let result = await Task.detached(priority: .userInitiated) { () -> LoadResult in
            // An edited copy reopens its own recipe on top of the original;
            // anything else starts a fresh edit that will save as a new copy.
            var source = item.url
            var sidecar: Sidecar?
            if let found = SidecarStore.load(forCopy: item.url) {
                let original = item.url.deletingLastPathComponent().appendingPathComponent(found.source)
                if FileManager.default.fileExists(atPath: original.path) {
                    source = original
                    sidecar = found
                }
            }
            if RawDecoder.isRaw(source) {
                let settings = sidecar?.recipe.raw
                let defaults = RawDecoder.preview(url: source, settings: nil)
                let edited = (settings?.isEmpty ?? true) ? defaults : RawDecoder.preview(url: source, settings: settings)
                return LoadResult(source: source, sidecar: sidecar, preview: nil, metadata: PhotoMetadata(),
                                  rawDefault: defaults, rawEdited: edited)
            }
            let preview = ImageLoading.downsampled(url: source, maxPixelSize: 2048)
            let metadata = PhotoMetadata.read(from: source)
            return LoadResult(source: source, sidecar: sidecar, preview: preview, metadata: metadata,
                              rawDefault: nil, rawEdited: nil)
        }.value

        sourceURL = result.source
        if let rawDefault = result.rawDefault, let rawEdited = result.rawEdited {
            defaultSource = rawDefault.image
            previewSource = rawEdited.image
            decodedRaw = result.sidecar?.recipe.raw
            rawDefaults = rawDefault.defaults
            fullSize = rawDefault.fullSize
            original = Renderer.makeUIImage(rawDefault.image)
        } else if RawDecoder.isRaw(result.source) {
            loadError = "Couldn't decode the RAW file \(result.source.lastPathComponent). Its camera may not be supported by this iPadOS version."
            return
        } else {
            guard let preview = result.preview, let cg = preview.cgImage else {
                loadError = "Couldn't open \(result.source.lastPathComponent)."
                return
            }
            original = preview
            previewSource = CIImage(cgImage: cg)
            if let w = result.metadata.pixelWidth, let h = result.metadata.pixelHeight {
                fullSize = CGSize(width: w, height: h)
            } else {
                fullSize = preview.size
            }
        }
        loadPresets()
        editingCopy = result.sidecar == nil ? nil : item.url
        savedRecipe = result.sidecar?.recipe ?? EditRecipe()
        isLoaded = true
        recipe = savedRecipe
        requestRender()
    }

    private struct LoadResult: Sendable {
        let source: URL
        let sidecar: Sidecar?
        let preview: UIImage?
        let metadata: PhotoMetadata
        let rawDefault: RawDecoder.Preview?
        let rawEdited: RawDecoder.Preview?
    }

    // MARK: Rendering

    private struct RenderJob: @unchecked Sendable {
        let source: CIImage
        let beforeSource: CIImage
        let recipe: EditRecipe
        let scale: CGFloat
        let mode: Renderer.GeometryMode
        let includeMarkup: Bool
        let highlightMask: UUID?
        let includeBefore: Bool

        func run() -> (after: UIImage?, before: UIImage?) {
            let after = Renderer.makeUIImage(Renderer.render(source, recipe: recipe, scale: scale, geometry: mode,
                                                             includeMarkup: includeMarkup, highlightMask: highlightMask))
            let before = includeBefore
                ? Renderer.makeUIImage(Renderer.render(beforeSource, recipe: recipe.geometryOnly, scale: scale))
                : nil
            return (after, before)
        }
    }

    private var needsBefore: Bool {
        (compareMode != .off || showOriginal) && Self.geometryMode(for: panel) == .full
            && renderedBeforeGeometry != recipe.geometry
    }

    private func requestRender() {
        needsRender = true
        guard renderTask == nil, previewSource != nil else { return }
        renderTask = Task { [weak self] in
            while true {
                guard let self, self.needsRender, self.previewSource != nil else { break }
                self.needsRender = false
                // RAW decoder settings changed: re-demosaic the preview first.
                let wantedRaw = self.recipe.raw?.isEmpty == false ? self.recipe.raw : nil
                if self.isRaw, wantedRaw != self.decodedRaw {
                    let url = self.sourceURL
                    self.isDecodingRaw = true
                    let decoded = await Task.detached(priority: .userInitiated) {
                        RawDecoder.preview(url: url, settings: wantedRaw)
                    }.value
                    self.isDecodingRaw = false
                    if let decoded {
                        self.previewSource = decoded.image
                        self.decodedRaw = wantedRaw
                    }
                    // Newer slider values may have arrived while decoding.
                    if self.recipe.raw?.isEmpty == false ? self.recipe.raw != wantedRaw : wantedRaw != nil {
                        self.needsRender = true
                        continue
                    }
                }
                guard let source = self.previewSource else { break }
                let mode = Self.geometryMode(for: self.panel)
                let scale = self.fullSize.width > 0 ? source.extent.width / self.fullSize.width : 1
                let includeBefore = self.needsBefore
                let job = RenderJob(source: source, beforeSource: self.defaultSource ?? source,
                                    recipe: self.recipe, scale: scale, mode: mode,
                                    includeMarkup: self.panel != .markup,
                                    highlightMask: self.panel == .masks && self.showMaskOverlay ? self.selectedMaskID : nil,
                                    includeBefore: includeBefore)
                let result = await Task.detached(priority: .userInitiated) { job.run() }.value
                self.rendered = result.after
                self.renderedMode = mode
                if includeBefore {
                    self.renderedBefore = result.before
                    self.renderedBeforeGeometry = job.recipe.geometry
                }
            }
            self?.renderTask = nil
        }
    }

    // MARK: Undo

    /// Call before a change begins (slider drag start, button tap) so it can be undone.
    func checkpoint() {
        if undoStack.last != recipe { undoStack.append(recipe) }
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func update(_ change: (inout EditRecipe) -> Void) {
        checkpoint()
        change(&recipe)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
    }

    func reset(group: Adjustment.Group) {
        update { r in
            for a in Adjustment.allCases where a.group == group { r[a] = 0 }
        }
    }

    func resetAll() {
        update { $0 = EditRecipe() }
    }

    func resetHSL() {
        update { r in
            for band in HSLBand.allCases {
                for channel in HSLChannel.allCases { r[band, channel] = 0 }
            }
        }
    }

    // MARK: RAW

    /// Current value of a RAW control (the camera default unless overridden).
    func rawValue(_ control: RawControl) -> Double {
        recipe.raw?[control] ?? rawDefaults?.value(control) ?? 0
    }

    func isRawDefault(_ control: RawControl) -> Bool { recipe.raw?[control] == nil }

    /// Live update while dragging (call `checkpoint()` when the drag starts).
    func setRaw(_ control: RawControl, _ value: Double?) {
        var raw = recipe.raw ?? RawSettings()
        if let value, let d = rawDefaults?.value(control),
           abs(value - d) < (control.range(default: d).upperBound - control.range(default: d).lowerBound) * 0.0005 {
            raw[control] = nil
        } else {
            raw[control] = value
        }
        recipe.raw = raw.isEmpty ? nil : raw
    }

    var lensCorrection: Bool {
        get { recipe.raw?.lensCorrection ?? rawDefaults?.lensCorrection ?? false }
        set {
            checkpoint()
            var raw = recipe.raw ?? RawSettings()
            raw.lensCorrection = newValue == rawDefaults?.lensCorrection ? nil : newValue
            recipe.raw = raw.isEmpty ? nil : raw
        }
    }

    var highlightRecovery: Bool {
        get { recipe.raw?.highlightRecovery ?? rawDefaults?.highlightRecovery ?? false }
        set {
            checkpoint()
            var raw = recipe.raw ?? RawSettings()
            raw.highlightRecovery = newValue == rawDefaults?.highlightRecovery ? nil : newValue
            recipe.raw = raw.isEmpty ? nil : raw
        }
    }

    func resetRaw(_ section: RawControl.Section) {
        update { r in
            guard var raw = r.raw else { return }
            for c in RawControl.allCases where c.section == section { raw[c] = nil }
            if section == .detail { raw.lensCorrection = nil }
            if section == .tone { raw.highlightRecovery = nil }
            r.raw = raw.isEmpty ? nil : raw
        }
    }

    func rawSectionIsDefault(_ section: RawControl.Section) -> Bool {
        guard let raw = recipe.raw else { return true }
        let controls = RawControl.allCases.filter { $0.section == section }.allSatisfy { raw[$0] == nil }
        switch section {
        case .detail: return controls && raw.lensCorrection == nil
        case .tone: return controls && raw.highlightRecovery == nil
        case .whiteBalance: return controls
        }
    }

    // MARK: Masks

    var masks: [MaskLayer] { recipe.masks ?? [] }
    var selectedMask: MaskLayer? { masks.first { $0.id == selectedMaskID } }

    func addMask(_ kind: MaskLayer.Kind) {
        let count = masks.filter { $0.kind == kind }.count
        var layer = MaskLayer(kind: kind, name: count == 0 ? kind.title : "\(kind.title) \(count + 1)")
        let size = sourceSize
        if kind == .radial, size.height > 0 {
            // Start as a circle on screen.
            layer.radiusY = layer.radiusX * size.width / size.height
        }
        update { r in r.masks = (r.masks ?? []) + [layer] }
        selectedMaskID = layer.id
        brushErase = false
    }

    func deleteMask(_ id: UUID) {
        update { r in
            r.masks?.removeAll { $0.id == id }
            if r.masks?.isEmpty == true { r.masks = nil }
        }
        if selectedMaskID == id { selectedMaskID = masks.last?.id }
    }

    /// Live change to a mask (call `checkpoint()` first for undo).
    func modifyMask(_ id: UUID, _ change: (inout MaskLayer) -> Void) {
        guard var all = recipe.masks, let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        recipe.masks = all
    }

    func beginStroke(at p: NPoint, pressure: Double) {
        guard let id = selectedMaskID, selectedMask?.kind == .brush else { return }
        checkpoint()
        let src = recipe.geometry.sourcePoint(fromOriented: p)
        let stroke = BrushStroke(points: [StrokePoint(x: src.x, y: src.y, p: pressure)],
                                 radius: brushSize, softness: brushSoftness, flow: brushFlow, erase: brushErase)
        modifyMask(id) { $0.strokes.append(stroke) }
    }

    func continueStroke(to p: NPoint, pressure: Double) {
        guard let id = selectedMaskID else { return }
        let src = recipe.geometry.sourcePoint(fromOriented: p)
        modifyMask(id) { layer in
            guard !layer.strokes.isEmpty else { return }
            layer.strokes[layer.strokes.count - 1].points.append(StrokePoint(x: src.x, y: src.y, p: pressure))
        }
    }

    // MARK: Heal

    var heals: [HealSpot] { recipe.heals ?? [] }

    /// Adds a spot at a point in the displayed (rotated/flipped) frame, sampling from nearby.
    func addHeal(at p: NPoint) {
        let target = recipe.geometry.sourcePoint(fromOriented: p)
        let size = sourceSize
        let minDim = max(1, min(size.width, size.height))
        if sampler == nil, let src = previewSource { sampler = PixelSampler(src) }
        // Best-matching nearby area; fall back to 2.5 radii toward the center.
        let offset = healSize * 2.5 * minDim
        let dirX: Double = target.x < 0.5 ? 1 : -1
        let fallback = NPoint(x: min(1, max(0, target.x + dirX * offset / max(1, size.width))), y: target.y)
        let source = sampler?.bestSource(for: target, radius: healSize, aspect: size.width / max(1, size.height))
            ?? fallback
        let spot = HealSpot(mode: healMode, target: target, source: source, radius: healSize)
        update { r in r.heals = (r.heals ?? []) + [spot] }
        selectedHealID = spot.id
    }

    func modifyHeal(_ id: UUID, _ change: (inout HealSpot) -> Void) {
        guard var all = recipe.heals, let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        recipe.heals = all
    }

    func deleteHeal(_ id: UUID) {
        update { r in
            r.heals?.removeAll { $0.id == id }
            if r.heals?.isEmpty == true { r.heals = nil }
        }
        if selectedHealID == id { selectedHealID = nil }
    }

    func removeAllHeals() {
        update { $0.heals = nil }
        selectedHealID = nil
    }

    // MARK: Markup

    var markup: Markup { recipe.markup ?? Markup() }

    private func setMarkup(_ m: Markup) {
        recipe.markup = m.isEmpty ? nil : m
    }

    /// Called when a PencilKit stroke finishes; `data` is already normalized to the reference width.
    func setDrawing(_ data: Data?) {
        guard data != recipe.markup?.drawing else { return }
        checkpoint()
        var m = markup
        m.drawing = data
        setMarkup(m)
    }

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checkpoint()
        var m = markup
        m.texts.append(TextItem(text: trimmed, position: NPoint(x: 0.5, y: 0.5), size: textSize, color: markupColor))
        setMarkup(m)
    }

    func moveText(_ id: UUID, to p: NPoint) {
        var m = markup
        guard let i = m.texts.firstIndex(where: { $0.id == id }) else { return }
        m.texts[i].position = NPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
        setMarkup(m)
    }

    func addShape(from a: NPoint, to b: NPoint) {
        checkpoint()
        var m = markup
        m.shapes.append(ShapeItem(kind: shapeKind, start: a, end: b, color: markupColor, lineWidth: shapeWidth))
        setMarkup(m)
    }

    func deleteMarkupItem(_ id: UUID) {
        checkpoint()
        var m = markup
        m.texts.removeAll { $0.id == id }
        m.shapes.removeAll { $0.id == id }
        setMarkup(m)
    }

    func clearMarkup() {
        update { $0.markup = nil }
    }

    // MARK: Curves

    func curve(_ channel: Curves.Channel) -> ToneCurve {
        (recipe.curves ?? Curves())[channel]
    }

    /// Live update while dragging (call `checkpoint()` when the drag starts).
    func setCurve(_ curve: ToneCurve, for channel: Curves.Channel) {
        var curves = recipe.curves ?? Curves()
        curves[channel] = curve
        recipe.curves = curves.isIdentity ? nil : curves
    }

    func resetCurve(_ channel: Curves.Channel) {
        checkpoint()
        setCurve(ToneCurve(), for: channel)
    }

    // MARK: Presets & copy/paste

    func applyPreset(_ preset: Preset) {
        update { $0.look = preset.look }
    }

    func copySettings() {
        SettingsClipboard.look = recipe.look
    }

    func pasteSettings() {
        guard let look = SettingsClipboard.look else { return }
        update { $0.look = look }
    }

    func loadPresets() {
        guard let root = presetsRoot else { return }
        Task {
            let loaded = await Task.detached { PresetStore.load(root: root) }.value
            userPresets = loaded
            renderPresetThumbnails(force: true)
        }
    }

    func saveCurrentAsPreset(named name: String) throws {
        guard let root = presetsRoot else { return }
        let preset = Preset(name: name.trimmingCharacters(in: .whitespaces), look: recipe.look)
        try PresetStore.save(preset, root: root)
        userPresets.append(preset)
        userPresets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        renderPresetThumbnails(force: true)
    }

    func updatePreset(_ preset: Preset, name: String? = nil, withCurrentLook: Bool = false) throws {
        guard let root = presetsRoot, let index = userPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = userPresets[index]
        if let name { updated.name = name.trimmingCharacters(in: .whitespaces) }
        if withCurrentLook { updated.look = recipe.look }
        try PresetStore.save(updated, root: root)
        userPresets[index] = updated
        if withCurrentLook { renderPresetThumbnails(force: true) }
    }

    func deletePreset(_ preset: Preset) throws {
        guard let root = presetsRoot else { return }
        try PresetStore.delete(preset, root: root)
        userPresets.removeAll { $0.id == preset.id }
    }

    /// Small previews of every preset on this photo (with the current crop).
    func renderPresetThumbnails(force: Bool = false) {
        guard let source = thumbnailSource, panel == .presets || force else { return }
        guard force || thumbnailGeometry != recipe.geometry || presetThumbnails.isEmpty else { return }
        thumbnailGeometry = recipe.geometry
        let geometry = recipe.geometry
        let presets = Preset.builtIn + userPresets
        let box = UncheckedBox(source)
        let scale = fullSize.width > 0 ? source.extent.width / fullSize.width : 0.05
        thumbnailTask?.cancel()
        thumbnailTask = Task {
            let images = await Task.detached(priority: .utility) { () -> [UUID: UIImage] in
                var out: [UUID: UIImage] = [:]
                var original = EditRecipe()
                original.geometry = geometry
                out[Preset.originalID] = Renderer.makeUIImage(Renderer.render(box.value, recipe: original, scale: scale))
                for preset in presets {
                    var recipe = EditRecipe()
                    recipe.geometry = geometry
                    recipe.look = preset.look
                    out[preset.id] = Renderer.makeUIImage(Renderer.render(box.value, recipe: recipe, scale: scale))
                }
                return out
            }.value
            if !Task.isCancelled { presetThumbnails = images }
        }
    }

    // MARK: Geometry actions

    func rotate(clockwise: Bool) {
        update { r in
            r.geometry.quarterTurns = ((r.geometry.quarterTurns + (clockwise ? 1 : 3)) % 4)
            r.geometry.crop = nil
            r.geometry.aspectPortrait.toggle()
        }
        applyAspectIfLocked()
    }

    func flip(horizontal: Bool) {
        update { r in
            if horizontal { r.geometry.flipHorizontal.toggle() } else { r.geometry.flipVertical.toggle() }
            if var crop = r.geometry.crop {
                if horizontal { crop.x = 1 - crop.x - crop.width } else { crop.y = 1 - crop.y - crop.height }
                r.geometry.crop = crop
            }
        }
    }

    /// Pixel width÷height the crop is locked to, or nil for free.
    var lockedAspectRatio: Double? {
        let g = recipe.geometry
        guard let landscape = g.aspect.landscapeRatio(original: baseSize) else { return nil }
        return g.aspectPortrait ? 1 / landscape : landscape
    }

    func setAspect(_ aspect: CropAspect) {
        let base = baseSize
        update { r in
            if r.geometry.aspect != aspect {
                r.geometry.aspect = aspect
                r.geometry.aspectPortrait = base.height > base.width
            }
        }
        applyAspectIfLocked()
    }

    func swapAspectOrientation() {
        update { $0.geometry.aspectPortrait.toggle() }
        applyAspectIfLocked()
    }

    /// Largest centered crop of the locked aspect ratio.
    private func applyAspectIfLocked() {
        guard let ratio = lockedAspectRatio else { return }
        let base = baseSize
        guard base.width > 0, base.height > 0 else { return }
        var w = base.width, h = base.width / ratio
        if h > base.height { h = base.height; w = h * ratio }
        let nw = w / base.width, nh = h / base.height
        recipe.geometry.crop = CropRect(x: (1 - nw) / 2, y: (1 - nh) / 2, width: nw, height: nh)
    }

    func resetGeometry() {
        update { $0.geometry = Geometry() }
    }

    // MARK: Saving

    /// Number of other edited copies made from this original (they lose their recipes on replace).
    func otherCopiesCount() -> Int {
        let folder = sourceURL.deletingLastPathComponent()
        return SidecarStore.copySources(in: folder)
            .filter { $0.value == sourceURL.lastPathComponent && folder.appendingPathComponent($0.key) != editingCopy }
            .count
    }

    func replaceOriginal(format: ExportFormat, quality: Double) async throws {
        isSaving = true
        defer { isSaving = false }
        let job = ReplaceOriginalJob(source: sourceURL, recipe: recipe, format: format, quality: quality,
                                     editingCopy: editingCopy)
        _ = try await Task.detached(priority: .userInitiated) { try job.run() }.value
        savedRecipe = recipe
    }

    /// Saves the edit. A new edit (or `asNewCopy`) writes a new file and leaves every
    /// existing copy alone; otherwise the copy being edited is updated in place.
    func save(format: ExportFormat, quality: Double, asNewCopy: Bool = false) async throws {
        isSaving = true
        defer { isSaving = false }
        let job = ExportJob(source: sourceURL, recipe: recipe, format: format, quality: quality,
                            updating: asNewCopy ? nil : editingCopy)
        let saved = try await Task.detached(priority: .userInitiated) { try job.run() }.value
        savedRecipe = saved.recipe
        if let output = saved.output {
            editingCopy = sourceURL.deletingLastPathComponent().appendingPathComponent(output)
        }
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension Preset {
    /// Thumbnail key for the "no preset" tile.
    static let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
