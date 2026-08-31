import CoreGraphics
import XCTest

/// The sums behind the mini player's scrolling titles. Worth pinning because two of them are
/// invisible when wrong in the obvious way and only show up as a twitch once a second: a `travel`
/// that leaves out the gap makes the loop jump, and an overflow test without tolerance makes
/// text that fits scroll by a fraction of a point forever.
final class MarqueeCycleTests: XCTestCase {

    // MARK: - When to scroll at all

    func testTextThatFitsDoesNotScroll() {
        let cycle = MarqueeCycle(contentWidth: 80, containerWidth: 120)
        XCTAssertFalse(cycle.scrolls)
        XCTAssertEqual(cycle.travel, 0)
        XCTAssertEqual(cycle.scrollDuration, 0)
    }

    func testTextExactlyFillingTheColumnDoesNotScroll() {
        XCTAssertFalse(MarqueeCycle(contentWidth: 120, containerWidth: 120).scrolls)
    }

    /// Sub-point overflow is measurement noise, not a title that needs reading. Without the
    /// tolerance every centred, nominally-fitting string would creep.
    func testOverflowWithinToleranceDoesNotScroll() {
        XCTAssertFalse(MarqueeCycle(contentWidth: 120.4, containerWidth: 120).scrolls)
    }

    func testOverflowBeyondToleranceScrolls() {
        XCTAssertTrue(MarqueeCycle(contentWidth: 121, containerWidth: 120).scrolls)
    }

    // MARK: - Layout that hasn't happened yet

    /// Both widths are 0 on the first pass, before anything has been measured.
    func testUnmeasuredLayoutDoesNotScroll() {
        XCTAssertFalse(MarqueeCycle(contentWidth: 0, containerWidth: 0).scrolls)
    }

    /// A view handed an unbounded proposal reports an infinite width; "infinitely wide column"
    /// is not a column the text overflows.
    func testInfiniteWidthsDoNotScroll() {
        XCTAssertFalse(MarqueeCycle(contentWidth: .infinity, containerWidth: 120).scrolls)
        XCTAssertFalse(MarqueeCycle(contentWidth: 200, containerWidth: .infinity).scrolls)
    }

    // MARK: - The loop

    /// The whole reason the reset at the end of a cycle is invisible: after travelling text plus
    /// gap, the second copy sits exactly where the first one started.
    func testTravelIsTextPlusGap() {
        let cycle = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44)
        XCTAssertEqual(cycle.travel, 344)
    }

    func testScrollDurationFollowsSpeed() {
        let cycle = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44, speed: 43)
        XCTAssertEqual(cycle.scrollDuration, 8, accuracy: 0.0001)
    }

    func testPauseIsCarriedThrough() {
        XCTAssertEqual(MarqueeCycle(contentWidth: 300, containerWidth: 120, pause: 1.5).pause, 1.5)
    }

    /// A negative pause would run the animator's first keyframe backwards; clamp instead.
    func testNegativePauseIsClamped() {
        XCTAssertEqual(MarqueeCycle(contentWidth: 300, containerWidth: 120, pause: -3).pause, 0)
    }

    /// Zero speed would be an infinite duration — an animation that never advances and never
    /// finishes. Better to leave the text truncated.
    func testZeroSpeedDoesNotScroll() {
        XCTAssertFalse(MarqueeCycle(contentWidth: 300, containerWidth: 120, speed: 0).scrolls)
    }

    // MARK: - Keeping two lines together

    /// A short line and a long one in the same group run loops of the same length: the pause
    /// plus the *longest* slide. That equality is what makes them start together forever after.
    func testEveryLineInAGroupRunsTheSameLengthOfLoop() {
        let long = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        let short = MarqueeCycle(contentWidth: 128, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        let shared = max(long.scrollDuration, short.scrollDuration)

        XCTAssertEqual(long.duration(sharedScroll: shared), 12, accuracy: 0.0001)
        XCTAssertEqual(
            short.duration(sharedScroll: shared),
            long.duration(sharedScroll: shared),
            accuracy: 0.0001
        )
    }

    /// The short line's whole reason for existing here: it finishes early and *waits*, parked at
    /// the end, instead of looping again while the long line is still going.
    func testShortLineWaitsAtTheEndForTheLongOne() {
        let short = MarqueeCycle(contentWidth: 128, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        let shared = 8.0  // a longer line's slide

        XCTAssertEqual(short.scrollDuration, 4, accuracy: 0.0001)
        // Done sliding at 4 + 4 = 8s, and still parked there four seconds later.
        XCTAssertEqual(short.offset(elapsed: 8, sharedScroll: shared), -short.travel, accuracy: 0.01)
        XCTAssertEqual(short.offset(elapsed: 11.9, sharedScroll: shared), -short.travel, accuracy: 0.01)
    }

    /// …and then both are back at the top of their text at the same instant.
    func testBothLinesStartAgainTogether() {
        let long = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        let short = MarqueeCycle(contentWidth: 128, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        let shared = max(long.scrollDuration, short.scrollDuration)
        let loop = long.duration(sharedScroll: shared)

        for cycle in [long, short] {
            XCTAssertEqual(cycle.offset(elapsed: loop, sharedScroll: shared), 0, accuracy: 0.01)
            // Still held at the start a moment into the new loop, and moving once the pause is up.
            XCTAssertEqual(cycle.offset(elapsed: loop + 1, sharedScroll: shared), 0, accuracy: 0.01)
            XCTAssertLessThan(cycle.offset(elapsed: loop + 4.5, sharedScroll: shared), 0)
        }
    }

    // MARK: - Position within a loop

    func testOffsetIsHeldAtTheStartThroughThePause() {
        let cycle = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        XCTAssertEqual(cycle.offset(elapsed: 0, sharedScroll: 0), 0)
        XCTAssertEqual(cycle.offset(elapsed: 3.9, sharedScroll: 0), 0)
    }

    func testOffsetIsLinearAcrossTheSlide() {
        let cycle = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        // Slide runs 4s→12s, so 8s is halfway and 10s is three quarters.
        XCTAssertEqual(cycle.offset(elapsed: 8, sharedScroll: 0), -cycle.travel / 2, accuracy: 0.01)
        XCTAssertEqual(cycle.offset(elapsed: 10, sharedScroll: 0), -cycle.travel * 0.75, accuracy: 0.01)
    }

    func testTextThatFitsNeverMoves() {
        let cycle = MarqueeCycle(contentWidth: 80, containerWidth: 120)
        XCTAssertEqual(cycle.offset(elapsed: 7, sharedScroll: 9), 0)
    }

    /// The clock is read as "now minus the group's epoch", and a clock that has just been reset
    /// can hand this a negative or non-finite interval. Neither should throw the text somewhere
    /// unreachable.
    func testNonsenseElapsedTimesAreSafe() {
        let cycle = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        XCTAssertEqual(cycle.offset(elapsed: -30, sharedScroll: 0), 0)
        XCTAssertEqual(cycle.offset(elapsed: .infinity, sharedScroll: 0), 0)
        XCTAssertEqual(cycle.offset(elapsed: .nan, sharedScroll: 0), 0)
    }

    /// A group whose longest line is shorter than this one's — or which hasn't measured yet —
    /// must not shorten this line's own slide.
    func testOwnSlideIsNeverCutShortByTheGroup() {
        let cycle = MarqueeCycle(contentWidth: 300, containerWidth: 120, gap: 44, speed: 43, pause: 4)
        XCTAssertEqual(cycle.duration(sharedScroll: 0), 12, accuracy: 0.0001)
        XCTAssertEqual(cycle.duration(sharedScroll: -5), 12, accuracy: 0.0001)
    }

    /// Every default is a number taken off the system's own bar; changing one changes how the
    /// app feels, so it should be a deliberate edit and not a drive-by.
    func testDefaultsMatchTheSystemBar() {
        XCTAssertEqual(MarqueeCycle.defaultSpeed, 45)
        XCTAssertEqual(MarqueeCycle.defaultPause, 4)
        XCTAssertEqual(MarqueeCycle.defaultGap, 44)
    }
}
