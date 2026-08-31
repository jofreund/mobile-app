import CoreGraphics

/// The timing of one marquee loop, kept apart from the view that draws it so it can be reasoned
/// about — and tested — without a running animation.
///
/// A cycle is *pause, slide, wait*: the text sits still long enough to be read from the start,
/// then slides left at a constant speed until the trailing copy has taken the leading copy's
/// place, and then holds there until the rest of its group has caught up. Because the trailing
/// copy lands exactly where the leading one started, that hold and the next cycle's pause are
/// indistinguishable, and the wrap between them is invisible — but only because `travel` counts
/// the gap between the two copies as well as the text itself. Get that wrong by a point and the
/// loop stutters.
///
/// **The wait is what keeps a title and its artist line together.** They are different lengths,
/// so at a shared speed they finish at different times; left to their own clocks they drift into
/// scrolling over each other, which is not what the system bar does. Instead every line in a
/// group runs a loop of the same length — the pause plus the *longest* slide in the group — and
/// spends the difference parked at the end. They therefore always set off together.
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

    /// How long one loop takes, given the longest slide in the group. Every line in a group gets
    /// the same answer, which is the whole point: same length, same start, same beat.
    func duration(sharedScroll: Double) -> Double {
        pause + max(scrollDuration, max(0, sharedScroll))
    }

    /// Where the text sits `elapsed` seconds after the group's loop began — 0 at rest, negative
    /// once moving, `-travel` while parked at the end waiting for a longer line to finish.
    ///
    /// A position derived from elapsed time rather than accumulated by an animation: two lines
    /// reading the same clock cannot drift apart, however they were laid out or when each of
    /// them first appeared.
    func offset(elapsed: Double, sharedScroll: Double) -> CGFloat {
        let total = duration(sharedScroll: sharedScroll)
        guard scrolls, total > 0, elapsed.isFinite else { return 0 }

        let phase = max(0, elapsed).truncatingRemainder(dividingBy: total) - pause
        guard phase > 0 else { return 0 }
        guard phase < scrollDuration else { return -travel }

        return -travel * CGFloat(phase / scrollDuration)
    }
}
