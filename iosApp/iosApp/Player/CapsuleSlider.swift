import SwiftUI
import UIKit

/// A slider in the shape Apple Music uses: a bare capsule with no handle, which swells while a
/// finger is on it and settles back when the finger lifts. Used for both the seek bar and the
/// volume control in the expanded player.
///
/// Replaces a stock `Slider`, whose thumb is the thing that makes it read as a *control* rather
/// than as a level. Without a thumb there is nothing to aim at, so the swell is what tells you
/// the touch landed — it has to carry the whole of that feedback, which is why the growth is
/// noticeable rather than subtle.
///
/// **A tap does not change the value.** Touching the bar swells it and nothing else; the value
/// only starts following the finger once the touch has travelled far enough to be a drag.
/// Changing on touch means every accidental brush of a bar this wide throws away your place in a
/// track, or puts the volume somewhere you did not ask for.
///
/// Three things here are less obvious than they look:
///
/// - **The row's height never changes.** The capsule grows inside a container of constant height
///   and stays centred. Letting the container grow would push the timestamps and the whole
///   transport down on every touch — the same defect that made the play/pause swap shift the
///   controls (see `PlayPauseIcon`).
/// - **The horizontal growth is a scale, not a wider frame.** Widening the frame would leave the
///   fill's own width computed against the old width, so the filled proportion would visibly
///   slip on touch. Scaling takes the fill with it.
/// - **The touch target is the whole container**, not the capsule. At rest the capsule is 6pt
///   tall; a 6pt target would be unusable, and the swell can only be triggered by a touch that
///   already landed.
struct CapsuleSlider: View {

    @Binding var value: Double
    let range: ClosedRange<Double>

    /// Step for VoiceOver's increment/decrement. A custom control gets none of `Slider`'s
    /// built-in adjustability, so it is re-supplied here rather than quietly lost.
    let step: Double

    /// Spoken form of the current value — the caller owns time formatting.
    let valueDescription: (Double) -> String

    /// `true` when a touch takes hold, `false` when it lifts. Mirrors `Slider`'s
    /// `onEditingChanged` so the call site's seek bookkeeping did not have to change.
    let onEditingChanged: (Bool) -> Void

    @State private var isScrubbing = false

    /// When the current touch landed, and the pending collapse it may have to wait for.
    ///
    /// A tap lifts within a few frames of landing, so swelling on touch-down and settling on
    /// touch-up put both animations in the same moment and the swell could pass unseen — the
    /// feedback the whole handle-less design rests on, lost precisely on the shortest gesture.
    /// Holding it briefly makes a tap look like a tap on both sliders instead of depending on
    /// how long a finger happened to linger.
    ///
    /// Only the *visual* settle waits. `onEditingChanged(false)` still fires immediately, so
    /// nothing about committing a value is delayed by this.
    @State private var touchBeganAt: Date?
    @State private var pendingCollapse: Task<Void, Never>?

    private let minimumSwell: TimeInterval = 0.3

    /// Where the finger landed, in the control's own coordinates.
    @State private var touchStartX: CGFloat?
    /// True once the touch has travelled far enough to count as a drag. Until then the bar is
    /// swollen but the value is untouched, which is what keeps a press from changing it.
    @State private var isDragging = false

    @Environment(\.isEnabled) private var isEnabled

    /// How far a touch must travel before it counts as a drag rather than a tap.
    private let dragActivation: CGFloat = 3

    /// How far each end reaches past its resting position while held, in points.
    ///
    /// Configurable because the two uses have different room: the seek bar spans the full
    /// content width with nothing beside it, while the volume bar sits between two speaker
    /// glyphs and can only grow into the gap.
    var activeOverhang: CGFloat = 8

    private let idleHeight: CGFloat = 6
    private let activeHeight: CGFloat = 14
    /// Constant row height: the tallest the capsule ever gets, plus room to touch.
    private let rowHeight: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(isScrubbing ? 0.24 : 0.18))
                Capsule()
                    .fill(Color.primary.opacity(isScrubbing ? 1 : 0.7))
                    .frame(width: filledWidth(in: width))
            }
            .frame(height: isScrubbing ? activeHeight : idleHeight)
            .scaleEffect(
                x: isScrubbing && width > 0 ? (width + activeOverhang * 2) / width : 1,
                y: 1,
                anchor: .center
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Touches come from a real `UIControl`, not a `DragGesture`.
            //
            // Measured: a SwiftUI drag gesture here was handed the touch 378–780ms after it
            // happened, against 26–110ms for the same control higher up the screen. Neither is
            // near a screen edge — the volume bar sits 156pt off the bottom and is *further*
            // from the sides than the seek bar — so the gate was never about position, and no
            // amount of rearranging this view was going to help.
            //
            // `UIScrollView` withholds touches from its content while it works out whether a
            // scroll is starting; `UIControl` is exempt, which is exactly why the stock `Slider`
            // this replaced never had the problem. UIKit owns the touch, SwiftUI draws every
            // pixel. See `SliderTouchTracker` for why owning touch-down is only half the job.
            .overlay {
                SliderTouchTracker(
                    onBegan: { location in began(at: location) },
                    onMoved: { location in moved(to: location, width: width) },
                    onEnded: { ended() }
                )
            }
        }
        .frame(height: rowHeight)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityValue(valueDescription(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func filledWidth(in width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0, width > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return width * CGFloat(min(max(fraction, 0), 1))
    }

    private func began(at location: CGPoint) {
        guard isEnabled else { return }
        touchStartX = location.x
        isDragging = false
        // A touch arriving during a held-open swell takes it over rather than letting the old
        // collapse fire underneath the new one.
        pendingCollapse?.cancel()
        pendingCollapse = nil
        touchBeganAt = Date()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isScrubbing = true
        }
        onEditingChanged(true)
    }

    private func moved(to location: CGPoint, width: CGFloat) {
        guard isEnabled, let startX = touchStartX, width > 0 else { return }

        if !isDragging {
            // Still just a press. Nothing is written to `value`, so a touch that never becomes a
            // drag leaves the value exactly where it was — which is the whole point of the
            // threshold, and why a tap cannot seek.
            guard abs(location.x - startX) >= dragActivation else { return }
            isDragging = true
        }

        // The value follows the finger's *position*, not its travel.
        //
        // This was relative for a while — moving by however far the finger had moved, from
        // wherever the value already was. That reads well in theory and badly in practice: unless
        // you happen to grab exactly on the playhead, the fill and your fingertip drift apart, and
        // dragging to a place does not put playback in that place.
        //
        // The cost is that the first movement past the threshold snaps the value to the finger.
        // That is the honest trade for direct manipulation, and it is still not a tap: nothing
        // moves until you have actually started dragging.
        //
        // Deliberately unanimated: the fill must sit under the finger, and easing it there reads
        // as lag.
        let span = range.upperBound - range.lowerBound
        let fraction = min(max(location.x / width, 0), 1)
        value = range.lowerBound + Double(fraction) * span
    }

    private func ended() {
        guard isEnabled else { return }
        touchStartX = nil
        isDragging = false
        // Immediately, so a committed seek or volume change is never held up by the animation.
        onEditingChanged(false)

        let held = touchBeganAt.map { Date().timeIntervalSince($0) } ?? minimumSwell
        let remaining = minimumSwell - held
        guard remaining > 0 else {
            settle()
            return
        }
        pendingCollapse = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            settle()
        }
    }

    @MainActor
    private func settle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isScrubbing = false
        }
    }
}

/// Hands the slider its touches through UIKit rather than a SwiftUI gesture.
///
/// `UIControl` is exempt from the delay `UIScrollView` imposes on ordinary content while it works
/// out whether a scroll is starting — measured at up to 780ms inside the expanded player's pager,
/// and the reason the stock `Slider` this replaced always felt immediate.
///
/// Owning the touch-down is only half of it. The pager's pan recognizer will still *cancel* a
/// touch it wants, turning a horizontal scrub into a page swipe, so scrolling is switched off for
/// as long as a finger is on the slider and switched back on when it lifts. `touchesShouldCancel`
/// is not the lever here: that governs the scroll view's own cancellation path, while a gesture
/// recognizer cancels touches in views by a different route entirely.
///
/// Draws nothing — the capsule underneath is entirely SwiftUI. This exists only to own the touch.
private struct SliderTouchTracker: UIViewRepresentable {

    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> TrackingControl {
        let control = TrackingControl()
        control.backgroundColor = .clear
        return control
    }

    func updateUIView(_ control: TrackingControl, context: Context) {
        // Reassigned rather than captured once: the closures come from the SwiftUI view, which is
        // a fresh value on every render, and a stale one would write to an old `value` binding.
        control.onBegan = onBegan
        control.onMoved = onMoved
        control.onEnded = onEnded
    }

    final class TrackingControl: UIControl {
        var onBegan: ((CGPoint) -> Void)?
        var onMoved: ((CGPoint) -> Void)?
        var onEnded: (() -> Void)?

        /// The scroll view paused for the duration of a touch, held so it can be restored.
        private weak var pausedScrollView: UIScrollView?

        private var enclosingScrollView: UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView { return scrollView }
                view = current.superview
            }
            return nil
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            // A drag that starts on a slider is for the slider, never for the page behind it.
            if let scrollView = enclosingScrollView, scrollView.isScrollEnabled {
                scrollView.isScrollEnabled = false
                pausedScrollView = scrollView
            }
            onBegan?(touch.location(in: self))
            return true
        }

        private func resumeScrolling() {
            pausedScrollView?.isScrollEnabled = true
            pausedScrollView = nil
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onMoved?(touch.location(in: self))
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            resumeScrolling()
            onEnded?()
        }

        deinit { pausedScrollView?.isScrollEnabled = true }

        /// Fires when the system takes the touch away — an incoming call, for instance. Without
        /// it the bar would stay swollen with no finger on it, and the pager would stay frozen.
        override func cancelTracking(with event: UIEvent?) {
            resumeScrolling()
            onEnded?()
        }
    }
}
