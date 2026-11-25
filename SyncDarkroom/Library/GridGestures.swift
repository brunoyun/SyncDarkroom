import SwiftUI
import UIKit

/// Adds a long-press-then-drag recognizer to the enclosing UIScrollView. Place it as the
/// background of the grid: reported locations are in this view's (the grid's) coordinates.
///
/// A UIKit recognizer is needed because SwiftUI drag gestures inside a ScrollView stop it
/// from scrolling. A long press only begins once the finger has been still for a moment,
/// so normal swipes keep scrolling.
struct LongPressDragProbe: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.probe = view
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var ancestor = superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            if let scrollView = ancestor as? UIScrollView { coordinator?.attach(to: scrollView) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: ((CGPoint) -> Void)?
        var onChanged: ((CGPoint) -> Void)?
        var onEnded: (() -> Void)?
        weak var probe: UIView?
        private weak var scrollView: UIScrollView?
        private var recognizer: UILongPressGestureRecognizer?

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else { return }
            detach()
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.minimumPressDuration = 0.35
            recognizer.allowableMovement = 12
            recognizer.delegate = self
            scrollView.addGestureRecognizer(recognizer)
            self.scrollView = scrollView
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer { scrollView?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            scrollView = nil
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let probe else { return }
            let location = recognizer.location(in: probe)
            switch recognizer.state {
            case .began:
                // Only when the press lands on the photo grid.
                guard probe.bounds.contains(location) else {
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
                scrollView?.panGestureRecognizer.isEnabled = false
                onBegan?(location)
            case .changed:
                onChanged?(location)
            case .ended, .cancelled, .failed:
                scrollView?.panGestureRecognizer.isEnabled = true
                onEnded?()
            default:
                break
            }
        }

        // Let the long press coexist with buttons (photo taps) underneath.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other is UIPanGestureRecognizer)
        }
    }
}
