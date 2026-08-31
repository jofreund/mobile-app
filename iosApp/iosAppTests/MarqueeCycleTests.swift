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

    /// Every default is a number taken off the system's own bar; changing one changes how the
    /// app feels, so it should be a deliberate edit and not a drive-by.
    func testDefaultsMatchTheSystemBar() {
        XCTAssertEqual(MarqueeCycle.defaultSpeed, 45)
        XCTAssertEqual(MarqueeCycle.defaultPause, 4)
        XCTAssertEqual(MarqueeCycle.defaultGap, 44)
    }
}
