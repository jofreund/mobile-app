import SwiftUI

/// A single line of text that scrolls itself when it is too long to fit, the way the system's own
/// now-playing bar does: a pause at the start, a slide left that eases in and glides to a halt, a
/// gap, and then the same text again. Track titles in a 120pt-wide column are routinely longer than the column — truncating
/// them ("We Didn't Know We Were Rea…") hides exactly the part that distinguishes one mix or
/// feature credit from another, which is the part you look at the mini player to check.
///
/// Timing lives in `MarqueeCycle`; this view is the drawing of it. Wrap several in a
/// `MarqueeGroup` — as the mini player's two lines are — and they keep step with each other
/// instead of drifting apart; on its own a line simply runs its own loop.
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

    /// How far past the text's resting position the visible area reaches on the leading side.
    ///
    /// The whole point of it: the leading fade lives *here*, outside where the text comes to
    /// rest, so at rest — and at the end of every loop, which looks the same — the first
    /// character is fully solid. Sit the text inside its own fade instead and the last thing a
    /// cycle does is snap that text from ghosted to solid, which is the one moment of a marquee
    /// anybody notices. The system bar leaves itself exactly this much room; the same trick is
    /// why its text seems to dissolve into the artwork rather than stop short of it.
    ///
    /// It bleeds into the row's 12pt gap beside the artwork, which is space no one was using.
    private static let leadingBleed: CGFloat = 12

    /// The width the row actually gives this line…
    @State private var containerWidth: CGFloat = 0
    /// …and the width the whole string wants. The comparison of the two is the entire question.
    @State private var contentWidth: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.marqueeClock) private var clock

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
            // What this line needs from the group's loop. A line that doesn't overflow still
            // reports its text, so the group can tell a track change from a re-measure.
            .preference(
                key: MarqueeMeasurementKey.self,
                value: MarqueeMeasurement(texts: [text], scrollDuration: cycle.scrollDuration)
            )
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
            // The position is computed from the group's clock every frame rather than handed to
            // an animation to run. An animation owns its own progress, so two of them started a
            // moment apart — or one restarted when its text changed — are permanently out of
            // step; two lines reading the same clock cannot be.
            TimelineView(.animation) { context in
                let offset = cycle.offset(
                    elapsed: context.date.timeIntervalSince(clock.epoch),
                    sharedScroll: clock.scrollDuration
                )
                // `Color.clear` takes whatever it is offered — here the column plus the bleed
                // below — so the mask is the size of the visible area and the copies sliding
                // through it are clipped to exactly that.
                Color.clear
                    .overlay(alignment: .leading) {
                        HStack(spacing: cycle.gap) {
                            line.lineLimit(1).fixedSize()
                            line.lineLimit(1).fixedSize()
                        }
                        // Rest at the far edge of the bleed, so `offset == 0` puts the text
                        // exactly where the plain `Text` it replaces would have sat.
                        .offset(x: Self.leadingBleed + offset)
                    }
                    .mask { fade }
                    // Claims the bleed without spending it: the negative padding hands the
                    // masked area an extra `leadingBleed` on the left and then reports the
                    // original width upwards, so nothing in the row moves.
                    .padding(.leading, -Self.leadingBleed)
            }
        } else {
            line.lineLimit(1)
        }
    }

    /// Opaque in the middle, dissolving at both edges — and fixed, because the bleed above has
    /// already put the leading fade somewhere the text does not sit still.
    ///
    /// Sized against the bled width, so the leading ramp finishes exactly where the text rests
    /// and the trailing one starts a fade's width from the far edge.
    private var fade: some View {
        let width = max(containerWidth + Self.leadingBleed, 1)
        let leading = min(Self.leadingBleed / width, 0.5)
        let trailing = min(Self.fadeWidth / width, 0.5)
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white, location: leading),
                .init(color: .white, location: 1 - trailing),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
