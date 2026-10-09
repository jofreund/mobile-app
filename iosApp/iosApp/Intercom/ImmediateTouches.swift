import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Stops the enclosing scroll view from sitting on a touch before it hands
    /// it to this view's gestures.
    ///
    /// A scroll view holds every touch that lands on its content for about a
    /// sixth of a second to see whether it turns into a scroll. That is right
    /// for a list of buttons and wrong for push-to-talk: the tile is held down
    /// but nothing happens, and the pop-over only starts growing once the
    /// scroll view has made up its mind.
    ///
    /// Losing the delay does not lose scrolling — the scroll view still claims
    /// the touch as soon as the finger travels far enough, which is exactly
    /// the same moment slide-to-cancel would have taken over anyway (the grid
    /// is locked while a tile is held).
    func immediateTouches() -> some View {
        #if canImport(UIKit)
        background { ScrollTouchDelayDisabler().frame(width: 0, height: 0) }
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
/// A zero-sized probe that finds the scroll view it was planted in and turns
/// off its touch delay. There is no SwiftUI spelling for this.
private struct ScrollTouchDelayDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view: UIView? = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    scrollView.delaysContentTouches = false
                    return
                }
                view = current.superview
            }
        }
    }
}
#endif
