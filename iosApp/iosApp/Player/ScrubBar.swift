import SwiftUI

/// The expanded player's seek control, in the shape Apple Music uses: a bare capsule with no
/// handle, which swells while a finger is on it and settles back when the finger lifts.
///
/// Replaces a stock `Slider`, whose thumb is the thing that makes it read as a *control* rather
/// than as a position. Without a thumb there is nothing to aim at, so the swell is what tells you
/// the touch landed — it has to carry the whole of that feedback, which is why the growth is
/// noticeable rather than subtle.
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
struct ScrubBar: View {

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

    @Environment(\.isEnabled) private var isEnabled

    private let idleHeight: CGFloat = 6
    private let activeHeight: CGFloat = 14
    /// How far each end reaches past its resting position while held, in points.
    private let activeOverhang: CGFloat = 8
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
            .gesture(scrub(width: width))
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

    private func scrub(width: CGFloat) -> some Gesture {
        // Zero minimum distance so a tap seeks too, rather than only a drag.
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }
                if !isScrubbing {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isScrubbing = true
                    }
                    onEditingChanged(true)
                }
                // Deliberately unanimated: the fill must sit under the finger, and easing it
                // there would read as lag.
                value = valueAt(x: gesture.location.x, width: width)
            }
            .onEnded { gesture in
                guard isEnabled else { return }
                value = valueAt(x: gesture.location.x, width: width)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isScrubbing = false
                }
                onEditingChanged(false)
            }
    }

    private func valueAt(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return range.lowerBound }
        let fraction = min(max(x / width, 0), 1)
        return range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
    }
}
