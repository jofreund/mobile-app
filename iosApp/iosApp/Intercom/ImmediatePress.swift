import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Reports a press from the touch-down itself, without waiting for any
    /// gesture arbitration.
    ///
    /// SwiftUI's own `DragGesture(minimumDistance: 0)` is the obvious way to
    /// do this and is not good enough inside a scroll view: it is arbitrated
    /// against the scroll view's pan before it may begin, which puts a
    /// long-press-like pause between the finger landing and anything
    /// happening. For push-to-talk that pause is the whole interaction.
    ///
    /// A `UILongPressGestureRecognizer` with a zero minimum duration begins in
    /// `touchesBegan`, so the pop-over starts growing in the frame the finger
    /// lands in. Scrolling survives: the recognizer runs alongside the scroll
    /// view's pan, and a finger that travels far enough scrolls the grid and
    /// cancels the press — which is what sliding off the card does anyway.
    ///
    /// - Parameters:
    ///   - isEnabled: Turns the whole thing off, touch handling included, so
    ///     controls underneath the card stay reachable.
    ///   - onBegan: The finger landed, at this point in the view's own
    ///     coordinates.
    ///   - onChanged: The finger moved, same coordinates.
    ///   - onEnded: The press finished. `true` means the system took the touch
    ///     away (a scroll started, a call came in) rather than the user
    ///     lifting a finger.
    func immediatePress(
        isEnabled: Bool = true,
        onBegan: @escaping (CGPoint) -> Void,
        onChanged: @escaping (CGPoint) -> Void,
        onEnded: @escaping (Bool) -> Void
    ) -> some View {
        #if canImport(UIKit)
        overlay {
            ImmediatePressRecognizer(
                isEnabled: isEnabled,
                onBegan: onBegan,
                onChanged: onChanged,
                onEnded: onEnded
            )
            .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
private struct ImmediatePressRecognizer: UIViewRepresentable {
    var isEnabled: Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        // Zero duration: recognised in the touch-down, not after a hold.
        recognizer.minimumPressDuration = 0
        // The finger is meant to travel — that is slide-to-cancel, not a
        // reason to give up on the press.
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        context.coordinator.recognizer = recognizer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        uiView.isUserInteractionEnabled = isEnabled
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ImmediatePressRecognizer
        weak var recognizer: UILongPressGestureRecognizer?

        init(_ parent: ImmediatePressRecognizer) {
            self.parent = parent
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began: parent.onBegan(location)
            case .changed: parent.onChanged(location)
            case .ended: parent.onEnded(false)
            case .cancelled, .failed: parent.onEnded(true)
            default: break
            }
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
