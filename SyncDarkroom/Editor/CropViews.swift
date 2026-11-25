import SwiftUI

struct CropPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Aspect Ratio").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(CropAspect.allCases) { aspect in
                    let selected = model.recipe.geometry.aspect == aspect
                    Button(aspect.title) { model.setAspect(aspect) }
                        .buttonStyle(.bordered)
                        .tint(selected ? .accentColor : .secondary)
                        .fontWeight(selected ? .semibold : .regular)
                }
            }
            Button {
                model.swapAspectOrientation()
            } label: {
                Label(model.recipe.geometry.aspectPortrait ? "Portrait" : "Landscape",
                      systemImage: model.recipe.geometry.aspectPortrait ? "rectangle.portrait" : "rectangle")
            }
            .disabled(model.recipe.geometry.aspect == .free || model.recipe.geometry.aspect == .square)

            Divider()

            Text("Rotate & Flip").font(.headline)
            HStack(spacing: 10) {
                iconButton("Rotate Left", "rotate.left") { model.rotate(clockwise: false) }
                iconButton("Rotate Right", "rotate.right") { model.rotate(clockwise: true) }
                iconButton("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    model.flip(horizontal: true)
                }
                iconButton("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    model.flip(horizontal: false)
                }
            }

            AdjustmentSlider(
                title: "Straighten",
                value: Binding(get: { model.recipe.geometry.straighten },
                               set: { model.recipe.geometry.straighten = $0 }),
                range: -45...45,
                format: { $0.formatted(.number.precision(.fractionLength(1))) + "°" },
                onBegin: { model.checkpoint() }
            )

            Divider()

            Text("Perspective").font(.headline)
            AdjustmentSlider(
                title: "Vertical",
                value: Binding(get: { model.recipe.geometry.perspectiveVertical },
                               set: { model.recipe.geometry.perspectiveVertical = $0 }),
                range: -100...100,
                format: Adjustment.contrast.format,
                onBegin: { model.checkpoint() }
            )
            AdjustmentSlider(
                title: "Horizontal",
                value: Binding(get: { model.recipe.geometry.perspectiveHorizontal },
                               set: { model.recipe.geometry.perspectiveHorizontal = $0 }),
                range: -100...100,
                format: Adjustment.contrast.format,
                onBegin: { model.checkpoint() }
            )

            Button("Reset Crop & Geometry", role: .destructive) { model.resetGeometry() }
                .font(.callout)
                .disabled(model.recipe.geometry == Geometry())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func iconButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }
}

/// Draggable crop rectangle over the straightened (uncropped) preview.
struct CropOverlay: View {
    @Binding var rect: CropRect
    /// Width ÷ height to keep, or nil for free cropping.
    let aspectRatio: Double?
    let onBegin: () -> Void

    private enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.size
            let r = CGRect(x: rect.x * bounds.width, y: rect.y * bounds.height,
                           width: rect.width * bounds.width, height: rect.height * bounds.height)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: bounds))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3
                        let y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(dragStart == nil ? 0.35 : 0.7), lineWidth: 0.5)
                .allowsHitTesting(false)

                Rectangle()
                    .path(in: r)
                    .stroke(Color.white, lineWidth: 1.5)
                    .allowsHitTesting(false)

                Color.white.opacity(0.001)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .gesture(dragGesture(handle: nil, bounds: bounds, current: r))

                ForEach(Handle.allCases, id: \.self) { handle in
                    CornerShape(handle: handle)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .square))
                        .frame(width: 22, height: 22)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                        .position(position(of: handle, in: r))
                        .gesture(dragGesture(handle: handle, bounds: bounds, current: r))
                }
            }
        }
    }

    private func position(of handle: Handle, in r: CGRect) -> CGPoint {
        // Offset so the L-shape sits just inside the corner.
        let inset: CGFloat = 11
        switch handle {
        case .topLeft: return CGPoint(x: r.minX + inset, y: r.minY + inset)
        case .topRight: return CGPoint(x: r.maxX - inset, y: r.minY + inset)
        case .bottomLeft: return CGPoint(x: r.minX + inset, y: r.maxY - inset)
        case .bottomRight: return CGPoint(x: r.maxX - inset, y: r.maxY - inset)
        }
    }

    private func dragGesture(handle: Handle?, bounds: CGSize, current: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = current
                    onBegin()
                }
                guard let start = dragStart else { return }
                let newRect = handle.map { resized(start, handle: $0, by: value.translation, bounds: bounds) }
                    ?? moved(start, by: value.translation, bounds: bounds)
                rect = CropRect(x: newRect.minX / bounds.width, y: newRect.minY / bounds.height,
                                width: newRect.width / bounds.width, height: newRect.height / bounds.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func moved(_ start: CGRect, by t: CGSize, bounds: CGSize) -> CGRect {
        var r = start
        r.origin.x = min(max(0, start.minX + t.width), bounds.width - start.width)
        r.origin.y = min(max(0, start.minY + t.height), bounds.height - start.height)
        return r
    }

    private func resized(_ s: CGRect, handle: Handle, by t: CGSize, bounds: CGSize) -> CGRect {
        let minSide: CGFloat = 44
        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let anchor = CGPoint(x: left ? s.maxX : s.minX, y: top ? s.maxY : s.minY)
        let corner = CGPoint(x: (left ? s.minX : s.maxX) + t.width, y: (top ? s.minY : s.maxY) + t.height)

        let maxW = left ? anchor.x : bounds.width - anchor.x
        let maxH = top ? anchor.y : bounds.height - anchor.y
        var w = min(max(left ? anchor.x - corner.x : corner.x - anchor.x, minSide), maxW)
        var h = min(max(top ? anchor.y - corner.y : corner.y - anchor.y, minSide), maxH)

        if let ratio = aspectRatio, ratio > 0 {
            if w / h > ratio { w = h * ratio } else { h = w / ratio }
        }
        return CGRect(x: left ? anchor.x - w : anchor.x, y: top ? anchor.y - h : anchor.y, width: w, height: h)
    }

    private struct CornerShape: Shape {
        let handle: Handle

        func path(in rect: CGRect) -> Path {
            var p = Path()
            switch handle {
            case .topLeft:
                p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            case .topRight:
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            case .bottomLeft:
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            case .bottomRight:
                p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            return p
        }
    }
}
