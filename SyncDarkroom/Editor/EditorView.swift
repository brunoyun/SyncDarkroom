import SwiftUI

struct EditorView: View {
    var onSaved: () -> Void = {}

    @State private var model: EditorModel
    @Environment(FolderStore.self) private var folderStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("exportFormat") private var exportFormat: ExportFormat = .jpeg
    @AppStorage("exportQuality") private var exportQuality: Double = 0.9
    @State private var confirmDiscard = false
    @State private var saveError: String?

    init(item: LibraryItem, onSaved: @escaping () -> Void = {}) {
        self.onSaved = onSaved
        _model = State(initialValue: EditorModel(item: item))
    }

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .compact {
                    VStack(spacing: 0) {
                        canvas
                        Divider()
                        EditorPanel(model: model).frame(height: 360)
                    }
                } else {
                    HStack(spacing: 0) {
                        canvas
                        Divider()
                        EditorPanel(model: model).frame(width: 350)
                    }
                }
            }
            .navigationTitle(model.sourceURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbar }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task {
            model.presetsRoot = folderStore.rootURL
            await model.load()
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let area = CGSize(width: max(1, geo.size.width - 40), height: max(1, geo.size.height - 40))
            ZStack {
                Color.black
                if let after = model.rendered {
                    canvasContent(after: after, area: area)
                } else if let error = model.loadError {
                    ContentUnavailableView("Can't Edit Photo", systemImage: "photo.badge.exclamationmark",
                                           description: Text(error))
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .overlay(alignment: .top) {
            if model.showOriginal {
                capsule(Text("Before").bold())
            } else if model.isLoaded && model.compareMode == .off {
                capsule(Text(model.saveDescription))
            }
        }
        .overlay {
            if model.isSaving {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Saving full-resolution copy…").font(.callout)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private func canvasContent(after: UIImage, area: CGSize) -> some View {
        let before = model.renderedBefore ?? model.original
        if model.panel == .crop {
            let size = fitted(after.size, in: area)
            Image(uiImage: after)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if model.renderedMode == .uncropped {
                        CropOverlay(
                            rect: Binding(
                                get: { model.recipe.geometry.crop ?? .full },
                                set: { model.recipe.geometry.crop = $0 }
                            ),
                            aspectRatio: model.lockedAspectRatio,
                            onBegin: { model.checkpoint() }
                        )
                    }
                }
        } else if [.masks, .heal, .markup].contains(model.panel) {
            let size = fitted(after.size, in: area)
            Image(uiImage: after)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .overlay {
                    // Only once the preview matches the panel's frame (orient-only vs. cropped).
                    if model.renderedMode == EditorModel.geometryMode(for: model.panel) {
                        switch model.panel {
                        case .masks: MaskCanvasOverlay(model: model, size: size)
                        case .heal: HealCanvasOverlay(model: model, size: size)
                        default: MarkupCanvasOverlay(model: model, size: size)
                        }
                    }
                }
        } else if model.compareMode == .split, let before {
            SplitCompareView(before: before, after: after)
                .frame(width: area.width, height: area.height)
        } else if model.compareMode == .sideBySide, let before {
            SideBySideCompareView(before: before, after: after)
                .frame(width: area.width, height: area.height)
        } else {
            let shown = model.showOriginal ? (before ?? after) : after
            let size = fitted(shown.size, in: area)
            Image(uiImage: shown)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                // Press and hold the photo to see it without your adjustments.
                .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 30, perform: {}, onPressingChanged: {
                    model.showOriginal = $0
                })
                .accessibilityHint("Touch and hold to show the photo before your adjustments")
        }
    }

    private func capsule(_ text: Text) -> some View {
        text
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 10)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
                if model.isDirty { confirmDiscard = true } else { dismiss() }
            }
            .disabled(model.isSaving)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

            Menu {
                Picker("Compare", selection: $model.compareMode) {
                    ForEach(EditorModel.CompareMode.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label("Compare", systemImage: model.compareMode == .off ? "square.split.2x1" : "square.split.2x1.fill")
            } primaryAction: {
                model.compareMode = model.compareMode == .off ? .split : .off
            }
            .disabled(!model.isLoaded || model.panel == .crop)
            .keyboardShortcut("y", modifiers: .command)

            Menu {
                Button("Copy Settings", systemImage: "doc.on.doc") { model.copySettings() }
                    .disabled(model.recipe.look.isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste Settings", systemImage: "doc.on.clipboard") { model.pasteSettings() }
                    .disabled(!model.hasCopiedSettings)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Reset All Edits", systemImage: "arrow.counterclockwise", role: .destructive) {
                    model.resetAll()
                }
                .disabled(model.recipe.isIdentity)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }

            Menu {
                if let copy = model.editingCopy {
                    Button("Update \(copy.lastPathComponent)", systemImage: "square.and.arrow.down") {
                        save()
                    }
                    Button("Save as New Copy", systemImage: "plus.square.on.square") {
                        save(asNewCopy: true)
                    }
                    Divider()
                }
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                Picker("Quality", selection: $exportQuality) {
                    Text("Maximum (100%)").tag(1.0)
                    Text("High (90%)").tag(0.9)
                    Text("Medium (80%)").tag(0.8)
                }
            } label: {
                Text("Save").bold()
            } primaryAction: {
                save()
            }
            .disabled(!model.isLoaded || model.isSaving || !model.isDirty)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private func save(asNewCopy: Bool = false) {
        Task {
            do {
                try await model.save(format: exportFormat, quality: exportQuality, asNewCopy: asNewCopy)
                onSaved()
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue = 0.0
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var onBegin: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(value == defaultValue ? .secondary : .primary)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onBegin()
                value = defaultValue
            }
            Slider(value: $value, in: range) { editing in
                if editing { onBegin() }
            }
        }
        .accessibilityHint("Double-tap the label to reset")
    }
}
