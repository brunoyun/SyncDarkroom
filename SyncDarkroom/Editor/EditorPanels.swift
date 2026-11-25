import SwiftUI

struct EditorPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(selection: $model.panel)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.panel {
                    case .presets: PresetsPanel(model: model)
                    case .light:
                        if model.isRaw { RawSection(model: model, section: .tone); Divider() }
                        adjustments(.light)
                    case .color:
                        if model.isRaw { RawSection(model: model, section: .whiteBalance); Divider() }
                        adjustments(.color)
                        Divider()
                        HSLSection(model: model)
                    case .curves: CurvesPanel(model: model)
                    case .detail:
                        if model.isRaw { RawSection(model: model, section: .detail); Divider() }
                        adjustments(.detail)
                    case .crop: CropPanel(model: model)
                    case .masks: MasksPanel(model: model)
                    case .heal: HealPanel(model: model)
                    case .markup: MarkupPanel(model: model)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(!model.isLoaded)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private func adjustments(_ group: Adjustment.Group) -> some View {
        let items = Adjustment.allCases.filter { $0.group == group }
        ForEach(items) { adjustment in
            AdjustmentSlider(
                title: adjustment.title,
                value: Binding(get: { model.recipe[adjustment] }, set: { model.recipe[adjustment] = $0 }),
                range: adjustment.range,
                format: adjustment.format,
                onBegin: { model.checkpoint() }
            )
        }
        Button("Reset \(group.rawValue.capitalized)") { model.reset(group: group) }
            .font(.callout)
            .disabled(items.allSatisfy { model.recipe[$0] == 0 })
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct PanelTabBar: View {
    @Binding var selection: EditorModel.Panel

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 5), spacing: 4) {
            ForEach(EditorModel.Panel.allCases) { panel in
                let selected = panel == selection
                Button {
                    selection = panel
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: panel.systemImage)
                            .font(.system(size: 17))
                            .frame(height: 22)
                        Text(panel.title)
                            .font(.system(size: 10, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .background(selected ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - HSL

extension HSLBand {
    var color: Color {
        switch self {
        case .red: Color(hue: 0 / 360, saturation: 0.85, brightness: 0.9)
        case .orange: Color(hue: 30 / 360, saturation: 0.9, brightness: 0.95)
        case .yellow: Color(hue: 55 / 360, saturation: 0.9, brightness: 0.95)
        case .green: Color(hue: 120 / 360, saturation: 0.7, brightness: 0.75)
        case .aqua: Color(hue: 180 / 360, saturation: 0.75, brightness: 0.85)
        case .blue: Color(hue: 225 / 360, saturation: 0.8, brightness: 0.95)
        case .purple: Color(hue: 270 / 360, saturation: 0.65, brightness: 0.85)
        case .magenta: Color(hue: 310 / 360, saturation: 0.7, brightness: 0.9)
        }
    }
}

private struct HSLSection: View {
    @Bindable var model: EditorModel
    @State private var band: HSLBand = .red

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Color Mixer").font(.headline)
                Spacer()
                Button("Reset") { model.resetHSL() }
                    .font(.callout)
                    .disabled(model.recipe.hslValues == nil)
            }
            HStack(spacing: 0) {
                ForEach(HSLBand.allCases) { b in
                    let edited = HSLChannel.allCases.contains { model.recipe[b, $0] != 0 }
                    Button {
                        band = b
                    } label: {
                        Circle()
                            .fill(b.color)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().stroke(Color.primary, lineWidth: b == band ? 2.5 : 0).padding(-4)
                            }
                            .overlay(alignment: .bottom) {
                                if edited { Circle().fill(Color.primary).frame(width: 4, height: 4).offset(y: 9) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(b.title)
                    .accessibilityAddTraits(b == band ? .isSelected : [])
                }
            }
            ForEach(HSLChannel.allCases) { channel in
                AdjustmentSlider(
                    title: "\(band.title) \(channel.title)",
                    value: Binding(get: { model.recipe[band, channel] }, set: { model.recipe[band, channel] = $0 }),
                    range: -100...100,
                    format: Adjustment.contrast.format,
                    onBegin: { model.checkpoint() }
                )
            }
        }
    }
}

// MARK: - Curves

private struct CurvesPanel: View {
    @Bindable var model: EditorModel
    @State private var channel: Curves.Channel = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Channel", selection: $channel) {
                ForEach(Curves.Channel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            CurveEditor(
                curve: Binding(get: { model.curve(channel) }, set: { model.setCurve($0, for: channel) }),
                channel: channel,
                onBegin: { model.checkpoint() }
            )
            .aspectRatio(1, contentMode: .fit)

            Text("Tap to add a point, drag to adjust, double-tap a point to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Menu("Shapes") {
                    Button("Medium Contrast") { setShape([(0, 0), (0.25, 0.21), (0.75, 0.79), (1, 1)]) }
                    Button("Strong Contrast") { setShape([(0, 0), (0.25, 0.16), (0.75, 0.84), (1, 1)]) }
                    Button("Faded Blacks") { setShape([(0, 0.1), (0.3, 0.32), (1, 1)]) }
                    Button("Soft Highlights") { setShape([(0, 0), (0.7, 0.7), (1, 0.92)]) }
                    Button("Linear") { setShape([(0, 0), (1, 1)]) }
                }
                Spacer()
                Button("Reset \(channel.title)") { model.resetCurve(channel) }
                    .disabled(model.curve(channel).isIdentity)
            }
            .font(.callout)
        }
    }

    private func setShape(_ points: [(Double, Double)]) {
        model.checkpoint()
        model.setCurve(ToneCurve(points: points.map { CurvePoint(x: $0.0, y: $0.1) }), for: channel)
    }
}

struct CurveEditor: View {
    @Binding var curve: ToneCurve
    let channel: Curves.Channel
    let onBegin: () -> Void

    @State private var dragIndex: Int?

    private var tint: Color {
        switch channel {
        case .rgb: .white
        case .red: .red
        case .green: .green
        case .blue: Color(red: 0.35, green: 0.55, blue: 1)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let samples = curve.sample(count: 128)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                Path { p in
                    for i in 1...3 {
                        let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    p.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Path { p in
                    for (i, y) in samples.enumerated() {
                        let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(samples.count - 1),
                                         y: size.height * (1 - y))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(tint, lineWidth: 2)
                ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(dragIndex == index ? tint : Color.black)
                        .overlay(Circle().stroke(tint, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(x: point.x * size.width, y: (1 - point.y) * size.height)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                removePoint(near: value.location, in: size)
            })
        }
    }

    private func normalized(_ location: CGPoint, in size: CGSize) -> CurvePoint {
        CurvePoint(x: min(1, max(0, location.x / size.width)), y: min(1, max(0, 1 - location.y / size.height)))
    }

    private func nearestIndex(to location: CGPoint, in size: CGSize, within radius: CGFloat = 28) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in curve.points.enumerated() {
            let d = hypot(p.x * size.width - location.x, (1 - p.y) * size.height - location.y)
            if d < radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var points = curve.points.sorted { $0.x < $1.x }
                if dragIndex == nil {
                    onBegin()
                    curve.points = points
                    if let index = nearestIndex(to: value.startLocation, in: size) {
                        dragIndex = index
                    } else if points.count < ToneCurve.maxPoints {
                        let new = normalized(value.startLocation, in: size)
                        // Start new points on the current curve so tapping doesn't jump.
                        let y = curve.sample(count: 256)[Int((new.x * 255).rounded())]
                        points.append(CurvePoint(x: new.x, y: y))
                        points.sort { $0.x < $1.x }
                        curve.points = points
                        dragIndex = points.firstIndex { $0.x == new.x }
                    } else {
                        return
                    }
                }
                guard let index = dragIndex, index < points.count else { return }
                var p = normalized(value.location, in: size)
                // Keep x between neighbours; endpoints may move inward.
                let minX = index > 0 ? points[index - 1].x + 0.01 : 0
                let maxX = index < points.count - 1 ? points[index + 1].x - 0.01 : 1
                p.x = min(max(p.x, minX), maxX)
                points[index] = p
                curve.points = points
            }
            .onEnded { _ in dragIndex = nil }
    }

    private func removePoint(near location: CGPoint, in size: CGSize) {
        guard let index = nearestIndex(to: location, in: size), curve.points.count > 2 else { return }
        let sorted = curve.points.sorted { $0.x < $1.x }
        // Endpoints stay; reset them to the corners instead.
        onBegin()
        var points = sorted
        if index == 0 { points[0] = CurvePoint(x: 0, y: 0) }
        else if index == points.count - 1 { points[index] = CurvePoint(x: 1, y: 1) }
        else { points.remove(at: index) }
        curve.points = points
    }
}

// MARK: - Presets

private struct PresetsPanel: View {
    @Bindable var model: EditorModel
    @State private var naming = false
    @State private var renaming: Preset?
    @State private var name = ""
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Presets").font(.headline)
                Spacer()
                Button("Save Current…", systemImage: "plus") {
                    name = ""
                    naming = true
                }
                .font(.callout)
                .disabled(model.recipe.look.isEmpty || model.presetsRoot == nil)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                tile(name: "Original", id: Preset.originalID, selected: model.recipe.look.isEmpty) {
                    model.update { $0.look = Look() }
                }
                ForEach(Preset.builtIn) { preset in
                    tile(name: preset.name, id: preset.id, selected: model.recipe.look == preset.look) {
                        model.applyPreset(preset)
                    }
                }
            }

            if !model.userPresets.isEmpty {
                Text("My Presets").font(.headline).padding(.top, 6)
                Text("Saved in the synced folder, so they appear on your other devices.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.userPresets) { preset in
                        tile(name: preset.name, id: preset.id, selected: model.recipe.look == preset.look) {
                            model.applyPreset(preset)
                        }
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                name = preset.name
                                renaming = preset
                            }
                            Button("Update with Current Settings", systemImage: "arrow.triangle.2.circlepath") {
                                perform { try model.updatePreset(preset, withCurrentLook: true) }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                perform { try model.deletePreset(preset) }
                            }
                        }
                    }
                }
            }
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { perform { try model.saveCurrentAsPreset(named: name) } }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current light, color, curves and detail settings (not the crop).")
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Rename") {
                if let preset = renaming { perform { try model.updatePreset(preset, name: name) } }
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Preset Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func tile(name: String, id: UUID, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Color.black.opacity(0.3)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image = model.presetThumbnails[id] {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - RAW

/// Decoder controls for RAW originals. They change how the RAW is developed, so moving
/// them re-decodes the preview (slower than the other sliders).
private struct RawSection: View {
    @Bindable var model: EditorModel
    let section: RawControl.Section

    private var title: String {
        switch section {
        case .whiteBalance: "RAW White Balance"
        case .tone: "RAW Tone"
        case .detail: "RAW Detail"
        }
    }

    var body: some View {
        if let defaults = model.rawDefaults {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.aperture").foregroundStyle(.tint)
                    Text(title).font(.headline)
                    if model.isDecodingRaw { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button(section == .whiteBalance ? "As Shot" : "Reset") { model.resetRaw(section) }
                        .font(.callout)
                        .disabled(model.rawSectionIsDefault(section))
                }
                ForEach(RawControl.allCases.filter { $0.section == section && defaults.supports($0) }) { control in
                    let d = defaults.value(control)
                    AdjustmentSlider(
                        title: control.title,
                        value: Binding(get: { model.rawValue(control) }, set: { model.setRaw(control, $0) }),
                        range: control.range(default: d),
                        defaultValue: d,
                        format: control.format,
                        onBegin: { model.checkpoint() }
                    )
                }
                if section == .tone && defaults.highlightRecoverySupported {
                    Toggle("Highlight Recovery", isOn: $model.highlightRecovery)
                }
                if section == .detail && defaults.lensCorrectionSupported {
                    Toggle("Lens Correction", isOn: $model.lensCorrection)
                }
                if section == .whiteBalance && model.rawSectionIsDefault(.whiteBalance) {
                    Text("As shot by the camera. Double-tap a slider's label to return to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
