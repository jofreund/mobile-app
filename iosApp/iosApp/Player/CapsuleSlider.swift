import SwiftUI
import UIKit
import os

/// Temporary. Answers one question: when a finger lands on a slider and stays still, how long
/// until the gesture is delivered? Logged for both sliders so the two can be compared directly —
/// the volume bar responds only once a drag starts, while the seek bar responds to the press
/// itself, and no amount of reading the view tree has explained the difference.
///
/// A late "touch-down" line means the touch is being withheld before it ever reaches the app
/// (arbitration or the system gesture gate). A prompt one means delivery is fine and the delay is
/// in rendering. Those are different bugs; remove this once it is clear which.
private let sliderLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.jofreund.taktgeber",
    category: "CapsuleSlider"
)

/// A slider in the shape Apple Music uses: a bare capsule with no handle, which swells while a
/// finger is on it and settles back when the finger lifts. Used for both the seek bar and the
/// volume control in the expanded player.
///
/// Replaces a stock `Slider`, whose thumb is the thing that makes it read as a *control* rather
/// than as a level. Without a thumb there is nothing to aim at, so the swell is what tells you
/// the touch landed — it has to carry the whole of that feedback, which is why the growth is
/// noticeable rather than subtle.
///
/// **A tap does not change the value.** Touching the bar swells it and nothing else; only
/// movement moves the value, and it moves *relative* to where the value already was. Changing on
/// touch means every accidental brush of a bar this wide throws away your place in a track, or
/// puts the volume somewhere you did not ask for.
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

    /// Temporary, for the delivery-latency logging above.
    var debugLabel: String = "?"

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
    /// Non-nil once the touch has travelled far enough to count as a drag. Until then the bar is
    /// swollen but the value is untouched, which is what keeps a press from changing it.
    @State private var dragStartX: CGFloat?
    /// The value the drag is measured from — captured when dragging starts, not when the finger
    /// lands.
    @State private var dragAnchorValue: Double?

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
            // scroll is starting, and `touchesShouldCancel(in:)` then steals them back mid-drag.
            // `UIControl` is exempt from both by default, which is exactly why the stock
            // `Slider` this replaced never had the problem. Borrowing that exemption is the
            // whole trick: UIKit owns the touch, SwiftUI still draws every pixel.
            .overlay {
                SliderTouchTracker(
                    onBegan: { location, timestamp in
                        began(at: location, timestamp: timestamp)
                    },
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

    private func began(at location: CGPoint, timestamp: TimeInterval) {
        guard isEnabled else { return }
        // `UITouch.timestamp` and `systemUptime` are the same clock, so this is the real gap
        // between the finger landing and the app hearing about it. Temporary.
        let latencyMs = Int((ProcessInfo.processInfo.systemUptime - timestamp) * 1000)
        sliderLog.info(
            "[\(debugLabel, privacy: .public)] down latency=\(latencyMs, privacy: .public)ms"
        )

        touchStartX = location.x
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
        guard isEnabled, let startX = touchStartX, width > 0 else { return }

        if dragStartX == nil {
            // Still just a press. Nothing is written to `value`, so a touch that never becomes a
            // drag leaves the value exactly where it was.
            guard abs(location.x - startX) >= dragActivation else { return }
            // Anchor on the value as it stands *now*, not as it stood when the finger landed — a
            // finger resting on a playing track would otherwise drag from a stale point. Anchoring
            // the x here too means crossing the threshold doesn't jolt by those first few points.
            dragStartX = location.x
            dragAnchorValue = value
        }

        guard let dragStartX, let anchor = dragAnchorValue else { return }
        // Movement is applied *relative* to where the value already was, rather than jumping to
        // wherever the finger is. Absolute mapping would satisfy "a press must not change the
        // value" only in the letter: the first few points of movement would still fling it across
        // the range. Relative also makes fine adjustment possible — nudging the end of a long
        // audiobook is a short movement, not an attempt to land a fingertip on the right pixel.
        //
        // Deliberately unanimated: the fill must sit under the finger, and easing it there reads
        // as lag.
        let span = range.upperBound - range.lowerBound
        let travelled = Double((location.x - dragStartX) / width) * span
        value = min(max(anchor + travelled, range.lowerBound), range.upperBound)
    }

    private func ended() {
        guard isEnabled else { return }
        touchStartX = nil
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

/// Hands the slider its touches through UIKit rather than a SwiftUI gesture.
///
/// A `UIControl` gets two things a plain view does not, both of them the reason the stock
/// `Slider` behaved and a `DragGesture` did not:
///
/// - **Touches arrive immediately.** `UIScrollView` withholds touches from ordinary content while
///   it decides whether a scroll is beginning. Measured at up to 780ms inside the expanded
///   player's pager.
/// - **They are not taken back.** `touchesShouldCancel(in:)` returns false for `UIControl` by
///   default, so a scroll view will not steal a drag mid-scrub the way it would from a plain view.
///
/// Draws nothing — the capsule underneath is entirely SwiftUI. This exists only to own the touch.
private struct SliderTouchTracker: UIViewRepresentable {

    /// Location within the control, and `UITouch.timestamp` — the same clock as `systemUptime`,
    /// which is what makes the delivery latency measurable at all.
    let onBegan: (CGPoint, TimeInterval) -> Void
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
        var onBegan: ((CGPoint, TimeInterval) -> Void)?
        var onMoved: ((CGPoint) -> Void)?
        var onEnded: (() -> Void)?

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onBegan?(touch.location(in: self), touch.timestamp)
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onMoved?(touch.location(in: self))
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            onEnded?()
        }

        /// Fires when the system takes the touch away — a call arriving, or a scroll that does
        /// win. Without it the bar would stay swollen with no finger on it.
        override func cancelTracking(with event: UIEvent?) {
            onEnded?()
        }
    }
}
