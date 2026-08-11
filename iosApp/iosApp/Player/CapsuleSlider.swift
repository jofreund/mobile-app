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

    /// Non-nil once the touch has travelled far enough to count as a drag. Until then the bar is
    /// swollen but the value is untouched, which is what keeps a tap from seeking.
    @State private var dragOrigin: CGFloat?
    /// The position the drag is measured from — captured when dragging starts, not when the
    /// finger lands.
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
            .contentShape(.rect)
            // High priority, not plain `.gesture`. A plain gesture has to be arbitrated against
            // every other recognizer that could claim the touch — the paging scroll view this
            // sits inside, and, for the volume bar, the mute Button sharing its HStack. That
            // arbitration is a wait, and the wait is visible: the volume bar swelled
            // perceptibly later than the seek bar, which has no such sibling. Claiming the touch
            // outright removes the wait, and there is nothing to lose by it — a drag that starts
            // on a slider is meant for the slider, never for the page behind it.
            .highPriorityGesture(scrub(width: width, frame: proxy.frame(in: .global)))
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

    private func scrub(width: CGFloat, frame: CGRect) -> some Gesture {
        // Zero minimum distance so the bar responds to the touch itself, not only to movement —
        // but see below: responding is not the same as seeking.
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }
                if !isScrubbing {
                    // `gesture.time` is not wall-clock here: subtracting it from `Date()` gave
                    // ~25 years, which is the span from Foundation's 2001 reference date, so it
                    // counts from boot. Compared against the same clock now. Both raw values are
                    // logged, so a wrong assumption shows as nonsense rather than as a
                    // plausible-looking number — which is exactly how the first attempt failed.
                    let event = gesture.time.timeIntervalSinceReferenceDate
                    let now = ProcessInfo.processInfo.systemUptime
                    let latencyMs = Int((now - event) * 1000)
                    sliderLog.info(
                        "[\(debugLabel, privacy: .public)] down latency=\(latencyMs, privacy: .public)ms y=\(Int(frame.minY), privacy: .public)...\(Int(frame.maxY), privacy: .public) x=\(Int(frame.minX), privacy: .public)...\(Int(frame.maxX), privacy: .public) screen=\(Int(UIScreen.main.bounds.height), privacy: .public)"
                    )
                    // A touch arriving during a held-open swell takes it over rather than
                    // letting the old collapse fire underneath the new gesture.
                    pendingCollapse?.cancel()
                    pendingCollapse = nil
                    touchBeganAt = Date()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isScrubbing = true
                    }
                    onEditingChanged(true)
                }

                let travel = gesture.translation.width
                if dragOrigin == nil {
                    // Still just a touch. Nothing is written to `value`, so a tap that never
                    // becomes a drag leaves the position exactly where it was.
                    guard abs(travel) >= dragActivation else { return }
                    // Anchor on the position as it stands *now*, not as it stood when the finger
                    // landed — a finger resting on a playing track would otherwise drag from a
                    // stale point. Recording the travel so far cancels it out, so crossing the
                    // threshold doesn't jolt the playhead by those first few points.
                    dragAnchorValue = value
                    dragOrigin = travel
                }

                // Deliberately unanimated: the fill must sit under the finger, and easing it
                // there would read as lag.
                value = draggedValue(travel: travel, width: width)
            }
            .onEnded { _ in
                guard isEnabled else { return }
                dragOrigin = nil
                dragAnchorValue = nil
                // Immediately, so a committed seek or volume change is never held up by the
                // animation below.
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
    }

    @MainActor
    private func settle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isScrubbing = false
        }
    }

    /// Movement is applied *relative* to where the playhead already was, rather than jumping to
    /// wherever the finger is.
    ///
    /// Absolute mapping would satisfy "a tap must not seek" only in the letter: the first few
    /// points of movement would still fling the playhead across the track, which is the jump the
    /// tap rule exists to prevent. Relative also makes small corrections possible — a fine
    /// adjustment near the end of a long audiobook is a short finger movement, not an attempt to
    /// land a fingertip on the right pixel.
    private func draggedValue(travel: CGFloat, width: CGFloat) -> Double {
        guard width > 0, let anchor = dragAnchorValue, let origin = dragOrigin else { return value }
        let span = range.upperBound - range.lowerBound
        let moved = Double((travel - origin) / width) * span
        return min(max(anchor + moved, range.lowerBound), range.upperBound)
    }
}
