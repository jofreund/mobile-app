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
/// **A tap does not change the value, and a drag moves it relatively.** Touching the bar swells it
/// and nothing else; once the touch travels far enough *sideways* to be a scrub, the value moves
/// by however far the finger has moved, from where it already was. Changing on touch means every
/// accidental brush of a bar this wide throws away your place in a track, or puts the volume
/// somewhere you did not ask for — and moving to sit under the fingertip means the playhead
/// teleports the instant a drag begins.
///
/// A touch that travels *downward* instead is not this control's at all, and is handed back to
/// whatever scrolls behind it. `SliderTouchTracker` owns that call and explains it.
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

    /// Set on the first movement `SliderTouchTracker` forwards: where the drag began, and the
    /// value it began from. Until then the bar is swollen but the value is untouched, which is
    /// what keeps a press from changing it.
    ///
    /// There is no threshold check here any more. The tracker forwards nothing until it has
    /// decided the gesture is a horizontal scrub, so the first movement that arrives is already
    /// a drag by definition — see `SliderTouchTracker` for where that decision is made and why
    /// it has to be made down there rather than up here.
    @State private var dragStartX: CGFloat?
    @State private var dragAnchorValue: Double?

    @Environment(\.isEnabled) private var isEnabled

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
                    onBegan: { began() },
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

    private func began() {
        guard isEnabled else { return }
        dragStartX = nil
        dragAnchorValue = nil
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
        guard isEnabled, width > 0 else { return }

        if dragStartX == nil {
            // First movement the tracker has let through, which means it has just committed the
            // gesture to this slider. Anchored on the value as it stands *now*, not as it stood
            // when the finger landed: a finger resting on a playing track would otherwise drag
            // from a stale point. Taking the x from here too means the points the finger spent
            // proving its intent do not land as a jolt.
            dragStartX = location.x
            dragAnchorValue = value
        }

        guard let dragStartX, let anchor = dragAnchorValue else { return }

        // Movement is *relative*: the value moves by however far the finger has moved, from where
        // it already was, rather than jumping to sit under the fingertip. This is what Apple Music
        // does, and it is the reason a scrubber can be adjusted precisely — a small correction is
        // a small movement, wherever on the bar you happened to grab.
        //
        // Absolute tracking was tried in between and reverted. It does put the fill under your
        // finger, but only by teleporting the playhead there the instant a press becomes a drag,
        // and no amount of easing that jump made it read as anything but a glitch.
        //
        // Deliberately unanimated: the fill has to track the finger, and easing it reads as lag.
        let span = range.upperBound - range.lowerBound
        let travelled = Double((location.x - dragStartX) / width) * span
        value = min(max(anchor + travelled, range.lowerBound), range.upperBound)
    }

    private func ended() {
        guard isEnabled else { return }
        dragStartX = nil
        dragAnchorValue = nil
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

/// Hands the slider its touches through UIKit rather than a SwiftUI gesture, and decides which
/// of the two — the slider or whatever scrolls behind it — the gesture actually belongs to.
///
/// `UIControl` is exempt from the delay `UIScrollView` imposes on ordinary content while it works
/// out whether a scroll is starting — measured at up to 780ms inside the expanded player's pager,
/// and the reason the stock `Slider` this replaced always felt immediate.
///
/// Owning the touch-down is only half of it. A pan recognizer will still *cancel* a touch it
/// wants, turning a horizontal scrub into a page swipe, so every ancestor that pans — scroll
/// views, the sheet's drag-to-dismiss, the pager — is switched off for the duration of a scrub;
/// `freezeAncestorPanning` covers why it has to be all of them. `touchesShouldCancel` is not the
/// lever here: that governs the scroll view's own cancellation path, while a gesture recognizer
/// cancels touches in views by a different route entirely.
///
/// **The decision waits for the finger to move.** This used to disable scrolling in
/// `beginTracking` — correct in the expanded player, where the slider is one control on a page
/// and the only thing behind it is a horizontal pager. It is wrong in the group settings sheet,
/// where a `VolumeSlider` sits in nearly every row of a vertical list: a touch anywhere near a
/// row would seize the whole gesture, so the list could barely be scrolled, and a scroll that
/// wobbled sideways by a few points moved somebody's volume instead.
///
/// So a touch stays ambiguous until it has travelled `intentThreshold` on either axis, and the
/// dominant axis settles it: horizontal is a scrub (claim the touch, freeze everything above it,
/// start forwarding movement), vertical is a scroll (resign — end tracking without ever writing
/// a value, and let the scroll view have it). Nothing is forwarded while undecided, which is
/// also what keeps a tap from changing the value; the caller has no threshold of its own.
///
/// Once it is a scrub it stays one for the whole touch. Nothing behind the bar moves again until
/// the finger lifts, however far the scrub wanders vertically on its way.
///
/// The threshold has to beat the scroll view's own hysteresis, which is around 10pt, or the pan
/// would recognize first and cancel us. 8pt clears it with a little room. Losing that race is not
/// fatal — disabling `isScrollEnabled` cancels a pan already in flight — but the list would twitch
/// first, so winning it outright is worth the margin.
///
/// Draws nothing — the capsule underneath is entirely SwiftUI. This exists only to own the touch.
private struct SliderTouchTracker: UIViewRepresentable {

    let onBegan: () -> Void
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
        var onBegan: (() -> Void)?
        var onMoved: ((CGPoint) -> Void)?
        var onEnded: (() -> Void)?

        /// What this touch has turned out to be. See the type doc for how the call is made.
        private enum Intent { case undecided, scrub, scroll }

        private var intent: Intent = .undecided
        /// Where the finger landed, in this control's coordinates — the origin the decision is
        /// measured from.
        private var touchStart: CGPoint?
        /// Guards against reporting the end of one touch twice: returning `false` from
        /// `continueTracking` ends tracking without `endTracking` being sent, so that path has to
        /// finish the gesture itself, and a later cancellation must not finish it again.
        private var hasFinished = false

        /// Everything paused for the duration of a scrub, held so it can all be restored.
        ///
        /// Strong references, deliberately: they live only as long as a finger is down, and a
        /// scroll view that vanished mid-scrub still has to be handed back its own setting rather
        /// than being left disabled for whoever holds it next.
        private var pausedScrollViews: [UIScrollView] = []
        private var pausedRecognizers: [UIGestureRecognizer] = []

        /// Dominant-axis travel that settles what the gesture is. Sized to land just inside a
        /// scroll view's own recognition hysteresis — see the type doc.
        private static let intentThreshold: CGFloat = 8

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            intent = .undecided
            hasFinished = false
            touchStart = touch.location(in: self)
            // Scrolling is deliberately left alone here. The gesture has not said what it is yet,
            // and seizing it on touch-down is what made a list of these unscrollable.
            onBegan?()
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let location = touch.location(in: self)

            switch intent {
            case .undecided:
                guard let start = touchStart else { return true }
                let dx = location.x - start.x
                let dy = location.y - start.y
                guard max(abs(dx), abs(dy)) >= Self.intentThreshold else { return true }

                guard abs(dx) > abs(dy) else {
                    // Theirs. Resign before a value is ever written, and stop tracking so the
                    // scroll view — which was never disabled — carries the gesture from here.
                    intent = .scroll
                    finish()
                    return false
                }

                intent = .scrub
                // Ours, and only now.
                freezeAncestorPanning()
                onMoved?(location)

            case .scrub:
                onMoved?(location)

            case .scroll:
                break
            }
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            finish()
        }

        /// Fires when the system takes the touch away — an incoming call, or a pan recognizer
        /// claiming a gesture we had not yet claimed ourselves. Without it the bar would stay
        /// swollen with no finger on it, and the scroll view would stay frozen.
        override func cancelTracking(with event: UIEvent?) {
            finish()
        }

        deinit { restoreAncestorPanning() }

        /// Stops *everything* above this control from panning for the rest of the scrub — not
        /// just the list the slider sits in.
        ///
        /// Freezing the nearest scroll view alone was not enough. In the group settings sheet the
        /// slider has three things above it that all pan: the list, the sheet's own
        /// drag-to-dismiss, and (in the expanded player) the pager. `isScrollEnabled` speaks only
        /// to the first — the sheet's dismissal is a recognizer on the presented view, not a
        /// scroll view at all, so a scrub with any downward slant in it dragged the sheet while
        /// the volume was being set.
        ///
        /// So: walk the whole ancestor chain, disable every scroll view and every pan recognizer
        /// on the way up, and remember exactly what was turned off. Disabling a recognizer
        /// mid-gesture cancels it, which is what makes this take effect on a pan that has already
        /// begun rather than only on the next one.
        ///
        /// Broad on purpose. It lasts only while a finger is on the bar, and everything is handed
        /// back in `restoreAncestorPanning` no matter how the touch ends.
        private func freezeAncestorPanning() {
            var view: UIView? = superview
            while let current = view {
                let scrollView = current as? UIScrollView
                if let scrollView, scrollView.isScrollEnabled {
                    scrollView.isScrollEnabled = false
                    pausedScrollViews.append(scrollView)
                }
                for recognizer in current.gestureRecognizers ?? [] {
                    // Already handled by `isScrollEnabled` above, and restoring it separately
                    // would only risk re-enabling it out of step with its own scroll view.
                    if recognizer === scrollView?.panGestureRecognizer { continue }
                    guard recognizer is UIPanGestureRecognizer, recognizer.isEnabled else { continue }
                    recognizer.isEnabled = false
                    pausedRecognizers.append(recognizer)
                }
                view = current.superview
            }
        }

        private func restoreAncestorPanning() {
            for scrollView in pausedScrollViews { scrollView.isScrollEnabled = true }
            for recognizer in pausedRecognizers { recognizer.isEnabled = true }
            pausedScrollViews.removeAll()
            pausedRecognizers.removeAll()
        }

        /// Idempotent: restores panning and reports the end exactly once per touch.
        private func finish() {
            touchStart = nil
            restoreAncestorPanning()
            guard !hasFinished else { return }
            hasFinished = true
            onEnded?()
        }
    }
}
