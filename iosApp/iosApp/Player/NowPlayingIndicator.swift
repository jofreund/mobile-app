import SwiftUI

/// The animated "this one is playing" equalizer — four bottom-anchored bars breathing out of
/// phase, after the Compose `NowPlayingIcon` this app shipped with (recoverable at `e2514156`):
/// same bar count, same 3:2 bar-to-gap proportions, drawn in the tint color. Deliberately
/// *slower and shallower* than that original (700ms legs over its 500ms, bars never dropping
/// below half height over its quarter) — at Compose's numbers the bars read as nervous
/// flickering next to a static list; these read as breathing. Tuned by eye on device.
///
/// The stagger comes from `.delay` on a `repeatForever` animation, which offsets only the first
/// start — after that each bar repeats on its own schedule, permanently out of phase with its
/// neighbours. That is the entire trick; there is no timeline driving this.
///
/// Under Reduce Motion the bars hold at full height: still legibly "the playing one", nothing
/// moving.
struct NowPlayingIndicator: View {

    var size: CGFloat = 16

    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 4
    private static let minScale: CGFloat = 0.5
    /// One leg of the breath (min→max or back). The stagger below is deliberately not a clean
    /// fraction of it, so the bars never fall into a repeating group pattern.
    private static let legDuration: Double = 0.7
    private static let staggerStep: Double = 0.23

    var body: some View {
        HStack(alignment: .bottom, spacing: size * 2 / 16) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Rectangle()
                    .fill(.tint)
                    .frame(width: size * 3 / 16, height: size)
                    .scaleEffect(
                        y: animating || reduceMotion ? 1 : Self.minScale,
                        anchor: .bottom
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: Self.legDuration)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * Self.staggerStep),
                        value: animating
                    )
            }
        }
        .frame(height: size)
        .onAppear { animating = true }
        // One element, not four bars — and it does carry information, so it is labeled rather
        // than hidden: it's how a VoiceOver user tells the playing player from the rest.
        .accessibilityElement()
        .accessibilityLabel(String(localized: "media_queue_now_playing"))
    }
}
