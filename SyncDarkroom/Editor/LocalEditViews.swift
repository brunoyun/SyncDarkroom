import PencilKit
import SwiftUI

// MARK: - Panels

struct MasksPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Masks").font(.headline)
                Spacer()
                Menu {
                    ForEach(MaskLayer.Kind.allCases, id: \.self) { kind in
                        Button(kind.title, systemImage: kind.systemImage) { model.addMask(kind) }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            if model.masks.isEmpty {
                Text("Add a mask to adjust part of the photo: paint with the brush (Apple Pencil pressure sets the size), or use a linear or radial gradient.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.masks) { layer in
                        maskRow(layer)
                    }
                }
            }

            if let layer = model.selectedMask {
                Divider()
                Toggle("Show Mask Overlay", isOn: $model.showMaskOverlay)
                Toggle("Invert", isOn: Binding(get: { layer.inverted }, set: { value in
                    model.checkpoint()
                    model.modifyMask(layer.id) { $0.inverted = value }
                }))

                switch layer.kind {
                case .brush:
                    Picker("Brush", selection: $model.brushErase) {
                        Label("Paint", systemImage: "paintbrush.pointed").tag(false)
                        Label("Erase", systemImage: "eraser").tag(true)
                    }
                    .pickerStyle(.segmented)
                    AdjustmentSlider(title: "Size", value: $model.brushSize, range: 0.005...0.3, defaultValue: 0.06,
                                     format: { "\(Int(($0 * 1000).rounded()))" })
                    AdjustmentSlider(title: "Softness", value: $model.brushSoftness, range: 0...1, defaultValue: 0.6,
                                     format: { "\(Int(($0 * 100).rounded()))" })
                    AdjustmentSlider(title: "Flow", value: $model.brushFlow, range: 0.05...1, defaultValue: 0.8,
                                     format: { "\(Int(($0 * 100).rounded()))" })
                    Text("Paint on the photo with your finger or Apple Pencil.")
                        .font(.caption).foregroundStyle(.secondary)
                case .linear:
                    Text("Drag the two handles: full effect at the solid line, fading out by the dashed one.")
                        .font(.caption).foregroundStyle(.secondary)
                case .radial:
                    AdjustmentSlider(
                        title: "Feather",
                        value: Binding(get: { layer.feather }, set: { v in model.modifyMask(layer.id) { $0.feather = v } }),
                        range: 0...1, defaultValue: 0.5,
                        format: { "\(Int(($0 * 100).rounded()))" },
                        onBegin: { model.checkpoint() }
                    )
                    Text("Drag the center to move, the edge handles to resize.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                Text("Adjustments in \(layer.name)").font(.headline)
                ForEach(MaskLayer.adjustableKeys) { adjustment in
                    AdjustmentSlider(
                        title: adjustment.title,
                        value: Binding(get: { model.selectedMask?[adjustment] ?? 0 },
                                       set: { v in model.modifyMask(layer.id) { $0[adjustment] = v } }),
                        range: adjustment.range,
                        format: adjustment.format,
                        onBegin: { model.checkpoint() }
                    )
                }
            }
        }
    }

    private func maskRow(_ layer: MaskLayer) -> some View {
        let selected = layer.id == model.selectedMaskID
        return HStack {
            Image(systemName: layer.kind.systemImage).frame(width: 24)
            Text(layer.name).lineLimit(1)
            if layer.adjustments.isEmpty {
                Text("no adjustments").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                model.deleteMask(layer.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(layer.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedMaskID = layer.id }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct HealPanel: View {
    @Bindable var model: EditorModel

    private var selected: HealSpot? { model.heals.first { $0.id == model.selectedHealID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spot Removal").font(.headline)
            Text("Tap a blemish or object to remove it. Drag the dashed circle to choose where the replacement comes from.")
                .font(.callout).foregroundStyle(.secondary)

            Picker("Mode", selection: Binding(get: { selected?.mode ?? model.healMode }, set: { mode in
                model.healMode = mode
                if let id = model.selectedHealID {
                    model.checkpoint()
                    model.modifyHeal(id) { $0.mode = mode }
                }
            })) {
                ForEach(HealSpot.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Heal blends the patch into its surroundings; Clone copies it exactly.")
                .font(.caption).foregroundStyle(.secondary)

            AdjustmentSlider(
                title: "Size",
                value: Binding(get: { selected?.radius ?? model.healSize }, set: { v in
                    model.healSize = v
                    if let id = model.selectedHealID { model.modifyHeal(id) { $0.radius = v } }
                }),
                range: 0.005...0.2, defaultValue: 0.04,
                format: { "\(Int(($0 * 1000).rounded()))" },
                onBegin: { model.checkpoint() }
            )
            if let spot = selected {
                AdjustmentSlider(
                    title: "Feather",
                    value: Binding(get: { spot.feather }, set: { v in model.modifyHeal(spot.id) { $0.feather = v } }),
                    range: 0...1, defaultValue: 0.5,
                    format: { "\(Int(($0 * 100).rounded()))" },
                    onBegin: { model.checkpoint() }
                )
            }

            HStack {
                Text("\(model.heals.count) spot\(model.heals.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                Button("Delete Selected", role: .destructive) {
                    if let id = model.selectedHealID { model.deleteHeal(id) }
                }
                .disabled(model.selectedHealID == nil)
                Button("Remove All", role: .destructive) { model.removeAllHeals() }
                    .disabled(model.heals.isEmpty)
            }
            .font(.callout)
        }
    }
}

struct MarkupPanel: View {
    @Bindable var model: EditorModel
    @State private var addingText = false
    @State private var newText = ""

    private var color: Binding<Color> {
        Binding(get: { Color(uiColor: model.markupColor.uiColor) },
                set: { model.markupColor = RGBAColor(UIColor($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Tool", selection: $model.markupTool) {
                ForEach(EditorModel.MarkupTool.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch model.markupTool {
            case .draw:
                Text("Draw with Apple Pencil; pick pens, colors and the eraser in the tool palette.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Draw with Finger", isOn: $model.drawWithFinger)
                Button("Clear Drawing", role: .destructive) { model.setDrawing(nil) }
                    .disabled(model.markup.drawing == nil)
            case .text:
                ColorPicker("Color", selection: color, supportsOpacity: false)
                AdjustmentSlider(title: "Size", value: $model.textSize, range: 0.015...0.2, defaultValue: 0.05,
                                 format: { "\(Int(($0 * 1000).rounded()))" })
                Button("Add Text…", systemImage: "textformat") {
                    newText = ""
                    addingText = true
                }
                Text("Drag a text's handle on the photo to move it.")
                    .font(.caption).foregroundStyle(.secondary)
                itemList(model.markup.texts.map { ($0.id, $0.text, "textformat") })
            case .shapes:
                HStack(spacing: 8) {
                    ForEach(ShapeItem.Kind.allCases, id: \.self) { kind in
                        Button {
                            model.shapeKind = kind
                        } label: {
                            Image(systemName: kind.systemImage).frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.shapeKind == kind ? .accentColor : .secondary)
                        .accessibilityLabel(kind.title)
                    }
                }
                ColorPicker("Color", selection: color, supportsOpacity: false)
                AdjustmentSlider(title: "Line Width", value: $model.shapeWidth, range: 0.001...0.03, defaultValue: 0.006,
                                 format: { "\(Int(($0 * 1000).rounded()))" })
                Text("Drag on the photo to draw the shape.")
                    .font(.caption).foregroundStyle(.secondary)
                itemList(model.markup.shapes.map { ($0.id, $0.kind.title, $0.kind.systemImage) })
            }

            Divider()
            Button("Clear All Markup", role: .destructive) { model.clearMarkup() }
                .disabled(model.recipe.markup == nil)
            Text("Markup is drawn on the final framed picture; changing the crop afterwards moves it with the frame.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Add Text", isPresented: $addingText) {
            TextField("Text", text: $newText)
            Button("Add") { model.addText(newText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func itemList(_ items: [(UUID, String, String)]) -> some View {
        ForEach(items, id: \.0) { id, title, icon in
            HStack {
                Image(systemName: icon).frame(width: 24)
                Text(title).lineLimit(1)
                Spacer()
                Button(role: .destructive) { model.deleteMarkupItem(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(title)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Canvas overlays

private func norm(_ p: CGPoint, _ size: CGSize) -> NPoint {
    NPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, p.y / size.height)))
}

private func pt(_ p: NPoint, _ size: CGSize) -> CGPoint {
    CGPoint(x: p.x * size.width, y: p.y * size.height)
}

/// Brush painting and gradient handles, over the rotated/flipped (uncropped) photo.
struct MaskCanvasOverlay: View {
    @Bindable var model: EditorModel
    let size: CGSize
    @State private var cursor: CGPoint?
    @State private var dragging = false

    var body: some View {
        let g = model.recipe.geometry
        ZStack(alignment: .topLeading) {
            if let layer = model.selectedMask {
                switch layer.kind {
                case .brush:
                    BrushCaptureView(
                        onBegin: { p, pressure in
                            cursor = p
                            model.beginStroke(at: norm(p, size), pressure: pressure)
                        },
                        onMove: { p, pressure in
                            cursor = p
                            model.continueStroke(to: norm(p, size), pressure: pressure)
                        },
                        onEnd: { cursor = nil },
                        onHover: { cursor = $0 }
                    )
                    if let cursor {
                        let d = model.brushSize * min(size.width, size.height) * 2
                        Circle()
                            .stroke(model.brushErase ? Color.white : Color.accentColor, lineWidth: 1.5)
                            .background(Circle().stroke(Color.black.opacity(0.5), lineWidth: 3))
                            .frame(width: d, height: d)
                            .position(cursor)
                            .allowsHitTesting(false)
                    }
                case .linear:
                    linearHandles(layer, g)
                case .radial:
                    radialHandles(layer, g)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "maskCanvas")
    }

    private func linearHandles(_ layer: MaskLayer, _ g: Geometry) -> some View {
        let a = pt(g.orientedPoint(fromSource: layer.linearStart), size)
        let b = pt(g.orientedPoint(fromSource: layer.linearEnd), size)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let perp = CGPoint(x: -sin(angle), y: cos(angle))
        let len = hypot(size.width, size.height)
        func across(_ c: CGPoint) -> Path {
            Path { p in
                p.move(to: CGPoint(x: c.x - perp.x * len, y: c.y - perp.y * len))
                p.addLine(to: CGPoint(x: c.x + perp.x * len, y: c.y + perp.y * len))
            }
        }
        return ZStack(alignment: .topLeading) {
            across(a).stroke(Color.white, lineWidth: 1.5)
            across(b).stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Color.white.opacity(0.6), lineWidth: 1)
            handle(at: a) { loc in
                model.modifyMask(layer.id) { $0.linearStart = g.sourcePoint(fromOriented: norm(loc, size)) }
            }
            handle(at: b) { loc in
                model.modifyMask(layer.id) { $0.linearEnd = g.sourcePoint(fromOriented: norm(loc, size)) }
            }
        }
        .clipped()
    }

    private func radialHandles(_ layer: MaskLayer, _ g: Geometry) -> some View {
        let src = model.sourceSize
        let orientedWidth = g.swapsAxes ? src.height : src.width
        let k = orientedWidth > 0 ? size.width / orientedWidth : 1
        let rxPx = layer.radiusX * src.width, ryPx = layer.radiusY * src.height
        let w = (g.swapsAxes ? ryPx : rxPx) * k, h = (g.swapsAxes ? rxPx : ryPx) * k
        let c = pt(g.orientedPoint(fromSource: layer.center), size)
        let inner = 1 - layer.feather
        return ZStack(alignment: .topLeading) {
            Ellipse().stroke(Color.white, lineWidth: 1.5)
                .frame(width: w * 2, height: h * 2).position(c).allowsHitTesting(false)
            Ellipse().stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .frame(width: w * 2 * inner, height: h * 2 * inner).position(c).allowsHitTesting(false)
            handle(at: c, symbol: "arrow.up.and.down.and.arrow.left.and.right") { loc in
                model.modifyMask(layer.id) { $0.center = g.sourcePoint(fromOriented: norm(loc, size)) }
            }
            handle(at: CGPoint(x: c.x + w, y: c.y)) { loc in
                let r = max(4, abs(loc.x - c.x)) / k
                model.modifyMask(layer.id) { m in
                    if g.swapsAxes { m.radiusY = r / src.height } else { m.radiusX = r / src.width }
                }
            }
            handle(at: CGPoint(x: c.x, y: c.y + h)) { loc in
                let r = max(4, abs(loc.y - c.y)) / k
                model.modifyMask(layer.id) { m in
                    if g.swapsAxes { m.radiusX = r / src.width } else { m.radiusY = r / src.height }
                }
            }
        }
    }

    private func handle(at point: CGPoint, symbol: String? = nil, onDrag: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .overlay {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(coordinateSpace: .named("maskCanvas"))
                    .onChanged { value in
                        if !dragging { dragging = true; model.checkpoint() }
                        onDrag(value.location)
                    }
                    .onEnded { _ in dragging = false }
            )
    }
}

/// Heal spot circles; tap empty space to add a spot.
struct HealCanvasOverlay: View {
    @Bindable var model: EditorModel
    let size: CGSize
    @State private var dragging = false

    var body: some View {
        let g = model.recipe.geometry
        let minDim = min(size.width, size.height)
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .onTapGesture(coordinateSpace: .local) { location in
                    model.addHeal(at: norm(location, size))
                }
            ForEach(model.heals) { spot in
                let t = pt(g.orientedPoint(fromSource: spot.target), size)
                let s = pt(g.orientedPoint(fromSource: spot.source), size)
                let r = spot.radius * minDim
                let selected = spot.id == model.selectedHealID
                let tint = selected ? Color.accentColor : Color.white
                Path { p in p.move(to: s); p.addLine(to: t) }
                    .stroke(tint.opacity(0.7), lineWidth: 1)
                    .allowsHitTesting(false)
                circle(center: s, radius: r, color: tint, dashed: true, selected: selected) { loc in
                    model.modifyHeal(spot.id) { $0.source = g.sourcePoint(fromOriented: norm(loc, size)) }
                } onTap: { model.selectedHealID = spot.id }
                circle(center: t, radius: r, color: tint, dashed: false, selected: selected) { loc in
                    model.modifyHeal(spot.id) { $0.target = g.sourcePoint(fromOriented: norm(loc, size)) }
                } onTap: { model.selectedHealID = spot.id }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "healCanvas")
    }

    private func circle(center: CGPoint, radius: CGFloat, color: Color, dashed: Bool, selected: Bool,
                        onDrag: @escaping (CGPoint) -> Void, onTap: @escaping () -> Void) -> some View {
        Circle()
            .stroke(color, style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: dashed ? [5, 4] : []))
            .background(Circle().stroke(Color.black.opacity(0.4), lineWidth: selected ? 4.5 : 3.5))
            .frame(width: radius * 2, height: radius * 2)
            .frame(width: max(44, radius * 2), height: max(44, radius * 2))
            .contentShape(Circle())
            .position(center)
            .onTapGesture(perform: onTap)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("healCanvas"))
                    .onChanged { value in
                        if !dragging { dragging = true; model.checkpoint(); onTap() }
                        onDrag(value.location)
                    }
                    .onEnded { _ in dragging = false }
            )
    }
}

/// Text/shape layer plus the live PencilKit canvas, over the final framed photo.
struct MarkupCanvasOverlay: View {
    @Bindable var model: EditorModel
    let size: CGSize
    @State private var shapeStart: CGPoint?
    @State private var shapeEnd: CGPoint?
    @State private var movingText = false

    var body: some View {
        let markup = model.markup
        ZStack(alignment: .topLeading) {
            if let vector = MarkupRenderer.image(markup, size: CGSize(width: size.width * 2, height: size.height * 2),
                                                 includeDrawing: false) {
                Image(uiImage: vector).resizable().frame(width: size.width, height: size.height).allowsHitTesting(false)
            }
            if let a = shapeStart, let b = shapeEnd {
                let preview = ShapeItem(kind: model.shapeKind, start: norm(a, size), end: norm(b, size),
                                        color: model.markupColor, lineWidth: model.shapeWidth)
                if let image = MarkupRenderer.image(Markup(shapes: [preview]), size: size, includeDrawing: false) {
                    Image(uiImage: image).allowsHitTesting(false)
                }
            }
            PencilCanvasView(
                drawingData: markup.drawing,
                size: size,
                isActive: model.markupTool == .draw,
                allowsFinger: model.drawWithFinger,
                onChange: { model.setDrawing($0) }
            )
            .frame(width: size.width, height: size.height)

            if model.markupTool == .shapes {
                Color.white.opacity(0.001)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                shapeStart = value.startLocation
                                shapeEnd = value.location
                            }
                            .onEnded { value in
                                model.addShape(from: norm(value.startLocation, size), to: norm(value.location, size))
                                shapeStart = nil
                                shapeEnd = nil
                            }
                    )
            }
            if model.markupTool == .text {
                ForEach(markup.texts) { text in
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(pt(text.position, size))
                        .gesture(
                            DragGesture(coordinateSpace: .named("markupCanvas"))
                                .onChanged { value in
                                    if !movingText { movingText = true; model.checkpoint() }
                                    model.moveText(text.id, to: norm(value.location, size))
                                }
                                .onEnded { _ in movingText = false }
                        )
                        .accessibilityLabel("Move text \(text.text)")
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "markupCanvas")
        .clipped()
    }
}

// MARK: - UIKit bridges

/// Captures single-finger or Apple Pencil strokes with pressure (SwiftUI gestures don't expose force).
struct BrushCaptureView: UIViewRepresentable {
    var onBegin: (CGPoint, Double) -> Void
    var onMove: (CGPoint, Double) -> Void
    var onEnd: () -> Void
    var onHover: (CGPoint?) -> Void

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        let hover = UIHoverGestureRecognizer(target: view, action: #selector(CaptureView.hovered(_:)))
        view.addGestureRecognizer(hover)
        return view
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.onBegin = onBegin
        view.onMove = onMove
        view.onEnd = onEnd
        view.onHover = onHover
    }

    final class CaptureView: UIView {
        var onBegin: ((CGPoint, Double) -> Void)?
        var onMove: ((CGPoint, Double) -> Void)?
        var onEnd: (() -> Void)?
        var onHover: ((CGPoint?) -> Void)?
        private weak var activeTouch: UITouch?

        private func pressure(_ touch: UITouch) -> Double {
            guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
            return Double(min(1, max(0.05, touch.force / touch.maximumPossibleForce)))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activeTouch == nil, let touch = touches.first else { return }
            activeTouch = touch
            onBegin?(touch.location(in: self), pressure(touch))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            for t in event?.coalescedTouches(for: touch) ?? [touch] {
                onMove?(t.location(in: self), pressure(t))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            activeTouch = nil
            onEnd?()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            touchesEnded(touches, with: event)
        }

        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: onHover?(recognizer.location(in: self))
            default: onHover?(nil)
            }
        }
    }
}

/// PencilKit canvas whose drawing is stored normalized to `Markup.referenceWidth`.
struct PencilCanvasView: UIViewRepresentable {
    let drawingData: Data?
    let size: CGSize
    let isActive: Bool
    let allowsFinger: Bool
    let onChange: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 6)
        // Ink colors are stored as-is and exported in light appearance; show them the same way
        // (otherwise PencilKit inverts black ink to white in the dark editor).
        canvas.overrideUserInterfaceStyle = .light
        context.coordinator.toolPicker.colorUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        context.coordinator.toolPicker.addObserver(canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        c.size = size
        canvas.drawingPolicy = allowsFinger ? .anyInput : .default
        canvas.isUserInteractionEnabled = isActive

        if c.lastData != drawingData || c.appliedSize != size {
            c.isApplying = true
            let drawing = drawingData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            let scale = size.width / Markup.referenceWidth
            canvas.drawing = drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
            c.lastData = drawingData
            c.appliedSize = size
            c.isApplying = false
        }

        c.toolPicker.setVisible(isActive, forFirstResponder: canvas)
        if isActive {
            DispatchQueue.main.async { canvas.becomeFirstResponder() }
        } else if canvas.isFirstResponder {
            canvas.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker.removeObserver(canvas)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        var onChange: ((Data?) -> Void)?
        var size: CGSize = .zero
        var appliedSize: CGSize = .zero
        var lastData: Data?
        var isApplying = false

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            guard !isApplying, size.width > 0 else { return }
            let scale = Markup.referenceWidth / size.width
            let normalized = canvas.drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
            let data = normalized.strokes.isEmpty ? nil : normalized.dataRepresentation()
            lastData = data
            onChange?(data)
        }
    }
}
