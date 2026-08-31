import SwiftUI

/// A single line of text that scrolls itself when it is too long to fit, the way the system's own
/// now-playing bar does: a pause at the start, a steady slide left, a gap, and then the same text
/// again. Track titles in a 120pt-wide column are routinely longer than the column — truncating
/// them ("We Didn't Know We Were Rea…") hides exactly the part that distinguishes one mix or
/// feature credit from another, which is the part you look at the mini player to check.
///
/// Timing lives in `MarqueeCycle`; this view is the drawing of it.
///
/// **Lays out exactly like the `Text` it replaces.** The visible copies are an *overlay* over a
/// hidden, ordinary, truncating `Text`, so the row's HStack sizes off that anchor and not off the
/// scrolling content — an HStack of two full-width copies asking for its ideal width would shove
/// the transport buttons off the end of the bar. The overlay never influences layout, and the
/// measuring copy in the background never does either.
///
/// Under Reduce Motion nothing scrolls: the text truncates, as it did before.
struct MarqueeText: View {

    let text: String

    var speed: CGFloat = MarqueeCycle.defaultSpeed
    var pause: Double = MarqueeCycle.defaultPause
    var gap: CGFloat = MarqueeCycle.defaultGap

    /// How much of each edge the fade covers. Matched by eye to the system bar — enough that
    /// glyphs dissolve rather than being sliced, not so much that a short word is half-ghosted.
    private static let fadeWidth: CGFloat = 12

    /// The width the row actually gives this line…
    @State private var containerWidth: CGFloat = 0
    /// …and the width the whole string wants. The comparison of the two is the entire question.
    @State private var contentWidth: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cycle: MarqueeCycle {
        MarqueeCycle(
            contentWidth: contentWidth,
            containerWidth: containerWidth,
            gap: gap,
            speed: speed,
            pause: pause
        )
    }

    var body: some View {
        // The anchor: an ordinary truncating line, invisible, there purely to be the size the
        // row lays out against.
        line
            .lineLimit(1)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .background(alignment: .leading) { measuringCopy }
            .overlay(alignment: .leading) { visibleCopies }
            // One string to a VoiceOver user, whatever it is doing on screen. The anchor and the
            // copies are all `.hidden()` or decorative, so without this the line would read as
            // nothing at all.
            .accessibilityElement()
            .accessibilityLabel(text)
    }

    private var line: Text {
        Text(text)
    }

    /// Never drawn, never laid out by the parent — `.fixedSize()` makes it report the width the
    /// string wants regardless of what the row proposes, which is the number `MarqueeCycle`
    /// needs and the one a truncating `Text` will not tell you.
    private var measuringCopy: some View {
        line
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
    }

    @ViewBuilder
    private var visibleCopies: some View {
        if cycle.scrolls, !reduceMotion {
            KeyframeAnimator(initialValue: CGFloat.zero, repeating: true) { offset in
                // `Color.clear` takes the anchor's size, so the mask below is the size of the
                // column and the copies sliding through it are clipped to it.
                Color.clear
                    .overlay(alignment: .leading) {
                        HStack(spacing: cycle.gap) {
                            line.lineLimit(1).fixedSize()
                            line.lineLimit(1).fixedSize()
                        }
                        .offset(x: offset)
                    }
                    // The leading fade comes in with the scroll rather than sitting there
                    // permanently: at rest the first character is fully solid, as it is in the
                    // system bar, and it only dissolves once there is text to its left.
                    .mask { fade(leading: min(1, -offset / Self.fadeWidth)) }
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(CGFloat.zero, duration: cycle.pause)
                    LinearKeyframe(-cycle.travel, duration: cycle.scrollDuration)
                }
            }
            // A new track — or a resize that changes the sums — starts a fresh cycle from the
            // beginning of the title, instead of continuing wherever the old one had got to.
            .id("\(text)|\(cycle.travel)")
        } else {
            line.lineLimit(1)
        }
    }

    /// Opaque in the middle, transparent at the trailing edge, and as transparent at the leading
    /// edge as `leading` (0…1) says.
    private func fade(leading: CGFloat) -> some View {
        let inset = min(Self.fadeWidth / max(containerWidth, 1), 0.5)
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(Double(1 - max(0, leading))), location: 0),
                .init(color: .white, location: inset),
                .init(color: .white, location: 1 - inset),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
