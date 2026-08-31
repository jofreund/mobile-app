import SwiftUI

/// The animated "this one is playing" equalizer — five bottom-anchored bars breathing out of
/// phase, after the Compose `NowPlayingIcon` this app shipped with (recoverable at `e2514156`):
/// same 3:2 bar-to-gap proportions, drawn in the tint color, one bar wider than its four.
/// Deliberately *slower and shallower* than that original (roughly 700ms legs over its 500ms, bars never
/// dropping much below half height over its quarter) — at Compose's numbers the bars read as
/// nervous flickering next to a static list; these read as breathing. Tuned by eye on device.
///
/// Each bar draws its own leg duration, depth and starting phase once, when the view is first
/// created, so no two bars breathe alike and the group never settles into a wave: the `.delay`
/// on a `repeatForever` animation offsets only the first start, and from then on the mismatched
/// durations keep pulling the bars apart instead of letting them regroup. That is the entire
/// trick; there is no timeline driving this.
///
/// Under Reduce Motion the bars hold at full height: still legibly "the playing one", nothing
/// moving.
struct NowPlayingIndicator: View {

    var size: CGFloat = 16

    @State private var animating = false
    /// Drawn once per view, never re-rolled — re-rolling mid-flight would restart the bars.
    @State private var bars = (0..<NowPlayingIndicator.barCount).map { _ in Bar() }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 5
    /// The bars stand a little shorter than the slot they occupy — at full `size` they crowd the
    /// row's text; a touch under reads as an accent beside it.
    private static let heightRatio: CGFloat = 14 / 16

    private var barHeight: CGFloat { size * Self.heightRatio }
    private var barWidth: CGFloat { size * 3 / 16 }

    /// One bar's share of the randomness: how long a leg of its breath takes (min→max or back),
    /// how far down it dips, and how far into its own cycle it starts.
    private struct Bar {
        let legDuration = Double.random(in: 0.55...0.95)
        let minScale = CGFloat.random(in: 0.25...0.6)
        let delay = Double.random(in: 0...0.5)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: size * 2 / 16) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                // Rounded to a pill. The `scaleEffect` below squashes the caps along with the
                // bar, so at the bottom of a breath they flatten slightly — at this radius the
                // difference is invisible, and it buys us not re-laying-out the row every frame
                // the way an animated `height` would.
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(.tint)
                    .frame(width: barWidth, height: barHeight)
                    .scaleEffect(
                        y: animating || reduceMotion ? 1 : bar.minScale,
                        anchor: .bottom
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: bar.legDuration)
                                .repeatForever(autoreverses: true)
                                .delay(bar.delay),
                        value: animating
                    )
            }
        }
        .frame(height: barHeight)
        .onAppear { animating = true }
        // One element, not five bars — and it does carry information, so it is labeled rather
        // than hidden: it's how a VoiceOver user tells the playing player from the rest.
        .accessibilityElement()
        .accessibilityLabel(String(localized: "media_queue_now_playing"))
    }
}
