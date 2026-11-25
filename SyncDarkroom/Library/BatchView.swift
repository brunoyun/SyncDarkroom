import CoreImage
import SwiftUI

struct BatchContext: Identifiable {
    let id = UUID()
    let items: [LibraryItem]
    let initialChoice: LookChoice?
}

enum LookChoice: Hashable {
    case copied
    case preset(UUID)
}

struct BatchView: View {
    let context: BatchContext
    var onFinished: () -> Void = {}

    @Environment(FolderStore.self) private var folderStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var exportFormat: ExportFormat = .jpeg
    @AppStorage("exportQuality") private var exportQuality: Double = 0.9

    @State private var choice: LookChoice?
    @State private var userPresets: [Preset] = []
    @State private var runner: BatchRunner?
    @State private var previewBase: PreviewBase?
    @State private var preview: UIImage?

    private struct PreviewBase: @unchecked Sendable {
        let image: CIImage
        let recipe: EditRecipe
        let scale: CGFloat
    }

    init(context: BatchContext, onFinished: @escaping () -> Void = {}) {
        self.context = context
        self.onFinished = onFinished
        _choice = State(initialValue: context.initialChoice)
    }

    private var copiedLook: Look? { SettingsClipboard.look }

    private var selectedLook: Look? {
        switch choice {
        case .copied: copiedLook
        case .preset(let id): (Preset.builtIn + userPresets).first { $0.id == id }?.look
        case nil: nil
        }
    }

    private var selectedName: String {
        switch choice {
        case .copied: "Copied Settings"
        case .preset(let id): (Preset.builtIn + userPresets).first { $0.id == id }?.name ?? ""
        case nil: ""
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let runner {
                    progress(runner)
                } else {
                    form
                }
            }
            .navigationTitle("Batch Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if runner == nil { Button("Cancel") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(runner?.isRunning == true)
        .task {
            if let root = folderStore.rootURL {
                userPresets = await Task.detached { PresetStore.load(root: root) }.value
            }
            await loadPreviewBase()
        }
        .task(id: choice) { await renderPreview() }
    }

    // MARK: Setup

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        Color.black.opacity(0.25)
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(context.items.count) photo\(context.items.count == 1 ? "" : "s")")
                            .font(.title2.bold())
                        Text(choice == nil ? "Choose a look below." : "Preview of \(selectedName) on \(context.items.first?.name ?? "")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Look") {
                if copiedLook != nil {
                    row("Copied Settings", systemImage: "doc.on.clipboard", value: .copied)
                }
                ForEach(Preset.builtIn) { preset in
                    row(preset.name, systemImage: "square.stack.3d.down.right", value: .preset(preset.id))
                }
                ForEach(userPresets) { preset in
                    row(preset.name, systemImage: "person.crop.square", value: .preset(preset.id))
                }
            }

            Section {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                Picker("Quality", selection: $exportQuality) {
                    Text("Maximum (100%)").tag(1.0)
                    Text("High (90%)").tag(0.9)
                    Text("Medium (80%)").tag(0.8)
                }
            } header: {
                Text("Save As")
            } footer: {
                Text("Each photo gets a new edited copy; originals and existing copies are never changed. Selected edited copies are redone from their original, keeping their crop, RAW, mask, heal and markup edits — only the look is replaced.")
            }

            Section {
                Button {
                    start()
                } label: {
                    Text("Create \(context.items.count) Edited Cop\(context.items.count == 1 ? "y" : "ies")")
                        .frame(maxWidth: .infinity)
                        .bold()
                }
                .disabled(selectedLook == nil)
            }
        }
    }

    private func row(_ title: String, systemImage: String, value: LookChoice) -> some View {
        Button {
            choice = value
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                if choice == value {
                    Image(systemName: "checkmark").foregroundStyle(.tint).bold()
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(choice == value ? .isSelected : [])
    }

    private func start() {
        guard let look = selectedLook else { return }
        let runner = BatchRunner(items: context.items)
        self.runner = runner
        let format = exportFormat, quality = exportQuality
        Task { await runner.run(look: look, format: format, quality: quality) }
    }

    // MARK: Progress

    private func progress(_ runner: BatchRunner) -> some View {
        VStack(spacing: 20) {
            Spacer()
            if runner.isFinished {
                Image(systemName: runner.failures.isEmpty && !runner.wasCancelled
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(runner.failures.isEmpty && !runner.wasCancelled ? Color.green : Color.orange)
                Text("Created \(runner.succeeded) edited cop\(runner.succeeded == 1 ? "y" : "ies")")
                    .font(.title2.bold())
                if runner.wasCancelled {
                    Text("Stopped after \(runner.completed) of \(runner.items.count).").foregroundStyle(.secondary)
                }
                if !runner.failures.isEmpty {
                    List(runner.failures) { failure in
                        VStack(alignment: .leading) {
                            Text(failure.name).bold()
                            Text(failure.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxHeight: 220)
                }
                Button("Done") {
                    onFinished()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView(value: Double(runner.completed), total: Double(max(1, runner.items.count)))
                    .frame(maxWidth: 360)
                Text("\(runner.completed) of \(runner.items.count)")
                    .font(.title3.bold())
                    .monospacedDigit()
                if let current = runner.current {
                    Text("Editing \(current)…").foregroundStyle(.secondary)
                }
                Text("Keep SyncDarkroom open until it finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Stop", role: .destructive) { runner.cancel() }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: Preview

    private func loadPreviewBase() async {
        guard let first = context.items.first else { return }
        let base = await Task.detached(priority: .userInitiated) { () -> PreviewBase? in
            let plan = BatchEdit.plan(for: first, look: Look())
            if RawDecoder.isRaw(plan.source) {
                guard let raw = RawDecoder.preview(url: plan.source, settings: plan.recipe.raw, maxPixelSize: 900)
                else { return nil }
                return PreviewBase(image: raw.image, recipe: plan.recipe, scale: raw.image.extent.width / raw.fullSize.width)
            }
            guard let ui = ImageLoading.downsampled(url: plan.source, maxPixelSize: 900), let cg = ui.cgImage else { return nil }
            let full = PhotoMetadata.read(from: plan.source).pixelWidth.map(CGFloat.init) ?? CGFloat(cg.width)
            return PreviewBase(image: CIImage(cgImage: cg), recipe: plan.recipe, scale: CGFloat(cg.width) / full)
        }.value
        previewBase = base
        await renderPreview()
    }

    private func renderPreview() async {
        guard let base = previewBase else { return }
        var recipe = base.recipe
        recipe.look = selectedLook ?? Look()
        let r = recipe
        preview = await Task.detached(priority: .userInitiated) {
            Renderer.makeUIImage(Renderer.render(base.image, recipe: r, scale: base.scale))
        }.value
    }
}
