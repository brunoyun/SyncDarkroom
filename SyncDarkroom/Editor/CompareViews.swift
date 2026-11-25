import SwiftUI

/// Before on the left of a draggable divider, after on the right.
struct SplitCompareView: View {
    let before: UIImage
    let after: UIImage
    @State private var position: CGFloat = 0.5
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let size = fitted(after.size, in: geo.size)
            ZStack(alignment: .leading) {
                Image(uiImage: after).resizable().interpolation(.high)
                Image(uiImage: before).resizable().interpolation(.high)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size.width * position)
                    }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: size.width * position - 1)
                Circle()
                    .fill(.white)
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.footnote.bold()).foregroundStyle(.black))
                    .offset(x: size.width * position - 17)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) { CompareLabel(text: "Before").padding(8) }
            .overlay(alignment: .topTrailing) { CompareLabel(text: "After").padding(8) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = position }
                        position = min(1, max(0, value.location.x / size.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .accessibilityElement()
            .accessibilityLabel("Before and after comparison")
            .accessibilityValue("\(Int(position * 100)) percent before")
            .accessibilityAdjustableAction { direction in
                position = min(1, max(0, position + (direction == .increment ? 0.1 : -0.1)))
            }
        }
    }
}

/// Before and after next to each other, stacked vertically when that fits better.
struct SideBySideCompareView: View {
    let before: UIImage
    let after: UIImage

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let horizontal = CGSize(width: (geo.size.width - spacing) / 2, height: geo.size.height)
            let vertical = CGSize(width: geo.size.width, height: (geo.size.height - spacing) / 2)
            let useHorizontal = fitted(after.size, in: horizontal).width * fitted(after.size, in: horizontal).height
                >= fitted(after.size, in: vertical).width * fitted(after.size, in: vertical).height
            let cell = useHorizontal ? horizontal : vertical
            let layout = useHorizontal
                ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
            layout {
                panel(before, label: "Before", in: cell)
                panel(after, label: "After", in: cell)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func panel(_ image: UIImage, label: String, in area: CGSize) -> some View {
        let size = fitted(image.size, in: area)
        return Image(uiImage: image).resizable().interpolation(.high)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) { CompareLabel(text: label).padding(8) }
            .frame(width: area.width, height: area.height)
    }
}

struct CompareLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}

func fitted(_ size: CGSize, in area: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
    let s = min(area.width / size.width, area.height / size.height)
    return CGSize(width: size.width * s, height: size.height * s)
}
