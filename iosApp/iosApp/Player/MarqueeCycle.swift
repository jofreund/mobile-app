import CoreGraphics

/// The timing of one marquee loop, kept apart from the view that draws it so it can be reasoned
/// about — and tested — without a running animation.
///
/// A cycle is *pause, then travel*: the text sits still long enough to be read from the start,
/// then slides left at a constant speed until the trailing copy has taken the leading copy's
/// place, at which point the offset resets by exactly one travel and the next cycle looks like a
/// seamless continuation. That reset is only invisible because `travel` counts the gap between
/// the two copies as well as the text itself — get that wrong by a point and the loop stutters.
///
/// The speed is taken off a screen recording of Apple Music's mini player rather than invented —
/// roughly 45pt/s; slower reads as sluggish next to the system's own bar, faster is hard to
/// follow in a 120pt-wide column. The rest between cycles is deliberately longer than the system
/// bar's: text that is *always* sliding is text you can never simply glance at, and the start of
/// a title is the part worth holding still.
struct MarqueeCycle: Equatable {

    /// Points per second, in the scrolling stretch.
    static let defaultSpeed: CGFloat = 45
    /// How long the start of the text is held still, at the top of every cycle — and so also the
    /// rest between one loop and the next, since the two are the same beat.
    static let defaultPause: Double = 4
    /// Empty space between the end of one copy and the start of the next. Wide enough that the
    /// wrap reads as "it started again" rather than as part of the sentence.
    static let defaultGap: CGFloat = 44

    /// Overflow under this is not worth animating: a text a fraction of a point too wide would
    /// otherwise scroll a fraction of a point, which looks like a glitch, not a marquee.
    private static let overflowTolerance: CGFloat = 0.5

    /// How far the content moves in one cycle — text width plus gap — or 0 when the text fits
    /// and there is nothing to scroll.
    let travel: CGFloat
    let gap: CGFloat
    let pause: Double
    let scrollDuration: Double

    var scrolls: Bool { travel > 0 }

    init(
        contentWidth: CGFloat,
        containerWidth: CGFloat,
        gap: CGFloat = MarqueeCycle.defaultGap,
        speed: CGFloat = MarqueeCycle.defaultSpeed,
        pause: Double = MarqueeCycle.defaultPause
    ) {
        self.gap = gap
        self.pause = max(0, pause)

        // Widths arrive from layout, which reports 0 before the first pass and — for a view that
        // is briefly given an unbounded proposal — can report infinity. Neither describes text
        // that overflows, so both mean "don't scroll yet".
        let measured = contentWidth.isFinite && containerWidth.isFinite
        let overflows = measured && containerWidth > 0
            && contentWidth > containerWidth + Self.overflowTolerance

        guard overflows, speed > 0 else {
            travel = 0
            scrollDuration = 0
            return
        }

        travel = contentWidth + gap
        scrollDuration = Double(travel / speed)
    }
}
