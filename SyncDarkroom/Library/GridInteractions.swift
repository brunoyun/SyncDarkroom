import Foundation
import Observation
import SwiftUI

/// Scroll position of the library, written on every scroll frame. Only the scrubber reads it
/// (and gesture handlers, outside of view updates), so scrolling doesn't re-render the grid.
@MainActor
@Observable
final class ScrollMetrics {
    /// Photo grid frame in the scroll view's (viewport) coordinates.
    var gridMinY: CGFloat = 0
    var gridWidth: CGFloat = 0
    /// Whole scroll content frame in viewport coordinates.
    var contentMinY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// How far the content can scroll.
    var scrollRange: CGFloat {
        max(0, contentHeight - (viewportHeight - topInset - bottomInset))
    }

    /// 0 at the top, 1 at the bottom.
    var scrollFraction: CGFloat {
        guard scrollRange > 1 else { return 0 }
        return min(1, max(0, (topInset - contentMinY) / scrollRange))
    }
}

/// Deletes photos from the synced folder (and the edit recipe of any edited copy).
enum PhotoDeletion {
    struct Failure: Sendable {
        let name: String
        let message: String
    }

    static func delete(_ urls: [URL]) -> [Failure] {
        var failures: [Failure] = []
        for url in urls {
            do {
                try coordinatedDelete(url)
                SidecarStore.remove(forCopy: url)
            } catch {
                failures.append(Failure(name: url.lastPathComponent, message: error.localizedDescription))
            }
        }
        return failures
    }
}

/// Fast-scroll column beside the grid: drag (or tap) anywhere on it to jump; a bubble shows
/// the month and year (or name/size, depending on the sort) at that position.
///
/// It sits in its own column rather than over the ScrollView: overlays on a ScrollView
/// don't receive drags (the scroll view's pan takes them).
struct FastScrubber: View {
    let metrics: ScrollMetrics
    let photos: [LibraryItem]
    let sortOrder: SortOrder
    let onScrub: (Int) -> Void

    static let width: CGFloat = 30

    @State private var dragFraction: CGFloat?
    @State private var bubbleIndex: Int?
    @State private var bubbleTask: Task<Void, Never>?
    @State private var recentlyScrolled = false
    @State private var hideTask: Task<Void, Never>?

    private let thumbHeight: CGFloat = 52

    private var isUseful: Bool {
        photos.count > 1 && metrics.scrollRange > metrics.viewportHeight * 0.75
    }

    var body: some View {
        GeometryReader { geo in
            let top = metrics.topInset + 8
            let bottom = metrics.bottomInset + 8
            let track = max(1, geo.size.height - top - bottom - thumbHeight)
            let shown = dragFraction ?? metrics.scrollFraction
            let y = top + shown * track + thumbHeight / 2
            let dragging = dragFraction != nil

            ZStack(alignment: .topLeading) {
                if isUseful {
                    // Track (shown while dragging).
                    Capsule()
                        .fill(Color.secondary.opacity(dragging ? 0.18 : 0))
                        .frame(width: 4, height: track + thumbHeight)
                        .position(x: geo.size.width / 2, y: top + (track + thumbHeight) / 2)

                    handle(dragging: dragging)
                        .position(x: geo.size.width / 2, y: y)

                    if let index = bubbleIndex, index < photos.count {
                        Text(label(for: photos[index]))
                            .font(.headline)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                            // Right-aligned just left of the column, over the grid (display only).
                            .frame(width: 320, alignment: .trailing)
                            .position(x: -160 - 6, y: y)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isUseful else { return }
                        if dragFraction == nil { UISelectionFeedbackGenerator().selectionChanged() }
                        scrub(to: value.location.y, top: top, track: track)
                    }
                    .onEnded { _ in endScrub() }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
            .animation(.easeOut(duration: 0.25), value: bubbleIndex == nil)
        }
        .ignoresSafeArea(edges: .vertical)
        .frame(width: Self.width)
        .opacity(dragFraction != nil || recentlyScrolled ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.3), value: recentlyScrolled)
        .onChange(of: metrics.scrollFraction) { flashVisible() }
        .accessibilityElement()
        .accessibilityLabel("Scroll position")
        .accessibilityValue(index(for: metrics.scrollFraction).map { label(for: photos[$0]) } ?? "")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 0.1 : -0.1
            if let index = index(for: min(1, max(0, metrics.scrollFraction + step))) { onScrub(index) }
        }
    }

    private func scrub(to centerY: CGFloat, top: CGFloat, track: CGFloat) {
        let f = min(1, max(0, (centerY - top - thumbHeight / 2) / track))
        dragFraction = f
        bubbleTask?.cancel()
        if let index = index(for: f), index != bubbleIndex {
            bubbleIndex = index
            onScrub(index)
        }
    }

    private func endScrub() {
        guard dragFraction != nil else { return }
        dragFraction = nil
        flashVisible()
        bubbleTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { bubbleIndex = nil }
        }
    }

    private func handle(dragging: Bool) -> some View {
        Capsule()
            .fill(dragging ? Color.accentColor : Color(uiColor: .systemGray))
            .frame(width: dragging ? 12 : 7, height: thumbHeight)
            .overlay {
                if dragging {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 2)
    }

    private func index(for fraction: CGFloat) -> Int? {
        guard !photos.isEmpty else { return nil }
        return min(photos.count - 1, max(0, Int((fraction * CGFloat(photos.count - 1)).rounded())))
    }

    private func label(for item: LibraryItem) -> String {
        switch sortOrder {
        case .dateNewest, .dateOldest:
            item.modified.formatted(.dateTime.month(.wide).year())
        case .nameAscending, .nameDescending:
            item.name
        case .sizeLargest:
            item.fileSize.formatted(.byteCount(style: .file))
        }
    }

    private func flashVisible() {
        recentlyScrolled = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { recentlyScrolled = false }
        }
    }
}
