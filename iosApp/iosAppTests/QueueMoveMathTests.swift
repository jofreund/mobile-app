import XCTest

/// The plan's highest-value untested target: three bugs shipped in this arithmetic before it had
/// any coverage. Each of those is pinned below as a named regression, alongside the ordinary
/// cases — a regression test that doesn't say which failure it guards tends to get "simplified"
/// back into the bug.
///
/// Vocabulary, since three coordinate systems meet here:
/// - **display index** — a position in the flattened rows, which omit the playing item's own
///   track row and interleave its chapters.
/// - **queue index** — absolute position in the queue.
/// - **`pos_shift`** — the server's target, measured *after* the source item is removed.
final class QueueMoveMathTests: XCTestCase {

    /// A plain queue of five tracks with nothing playing: display index == queue index.
    private let plainRows: [Int?] = [0, 1, 2, 3, 4]

    // MARK: - Regressions

    /// Shipped bug #1. `handleMove` required a current item before dispatching, so a queue that
    /// was loaded but idle — `QueueInfo.currentItem` is genuinely nullable — dropped *every*
    /// reorder. Especially cruel because with nothing playing, nothing is "already played", so
    /// every row is draggable and every drag silently vanished.
    func testIdleQueueWithNoCurrentItemAllowsReordering() throws {
        let move = try XCTUnwrap(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 3, to: 1, currentQueueIndex: nil),
            "a queue with nothing playing must still reorder"
        )
        XCTAssertEqual(move.fromQueueIndex, 3)
        XCTAssertEqual(move.serverToIndex, 1)
    }

    /// …including a drop at the very front, which is the position the current-item floor would
    /// otherwise reject. No current item means no floor.
    func testIdleQueueAllowsDropAtTheFront() {
        XCTAssertNotNil(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 4, to: 0, currentQueueIndex: nil)
        )
    }

    /// Shipped bug #2: the pre- vs post-removal convention. `Array.move`/`.onMove` want a
    /// pre-removal offset; the server's `pos_shift` is measured after the source is removed.
    /// Sending the unadjusted index overshot every forward drag by one — it looked right locally
    /// and landed one position off on the server.
    func testForwardMoveShiftsTheServerIndexBackByOne() throws {
        let move = try XCTUnwrap(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 1, to: 4, currentQueueIndex: 0)
        )
        XCTAssertEqual(move.localToIndex, 4, "the optimistic local reorder wants the pre-removal offset")
        XCTAssertEqual(move.serverToIndex, 3, "the server wants it post-removal")
    }

    /// Backward moves are unaffected: removing the source never shifts indices before it.
    func testBackwardMoveLeavesTheServerIndexAlone() throws {
        let move = try XCTUnwrap(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 4, to: 2, currentQueueIndex: 0)
        )
        XCTAssertEqual(move.localToIndex, 2)
        XCTAssertEqual(move.serverToIndex, 2)
    }

    /// Shipped bug #3: the target index was derived by *counting* rows up to the drop point,
    /// which undercounts by exactly the number of omitted rows before it. Here the playing item
    /// (queue index 2) has its track row omitted and two chapter rows in its place, so display
    /// and queue indices diverge — counting would produce a different answer than reading.
    func testReadsTheStoredQueueIndexRatherThanCountingRows() throws {
        // display:  0    1    2       3       4    5
        // queue:    0    1    (2 playing, as chapters)  3    4
        let rows: [Int?] = [0, 1, nil, nil, 3, 4]

        let move = try XCTUnwrap(
            QueueMoveMath.resolve(rowQueueIndices: rows, from: 5, to: 4, currentQueueIndex: 2)
        )
        // Display index 4 holds queue index 3 — not 4, which is what counting rows would give.
        XCTAssertEqual(move.localToIndex, 3)
        XCTAssertEqual(move.fromQueueIndex, 4)
    }

    // MARK: - The current-item floor

    func testRejectsDropOntoTheCurrentItem() {
        XCTAssertNil(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 4, to: 2, currentQueueIndex: 2)
        )
    }

    func testRejectsDropBeforeTheCurrentItem() {
        XCTAssertNil(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 4, to: 0, currentQueueIndex: 2)
        )
    }

    func testAllowsDropImmediatelyAfterTheCurrentItem() {
        XCTAssertNotNil(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 4, to: 3, currentQueueIndex: 2)
        )
    }

    // MARK: - Drop-position resolution

    /// SwiftUI hands `.onMove` a `to` of `count` when something is dropped past the last row.
    /// The slice `rows[to...]` is empty there, so this falls back to "after the last track".
    func testDropPastTheEndLandsAfterTheLastTrack() throws {
        let move = try XCTUnwrap(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 0, to: 5, currentQueueIndex: nil)
        )
        XCTAssertEqual(move.localToIndex, 5)
        XCTAssertEqual(move.serverToIndex, 4)
    }

    /// Dropping onto a chapter row resolves to the next real track, not the chapter's parent.
    func testDropOnAChapterRowResolvesToTheFollowingTrack() {
        let rows: [Int?] = [0, nil, nil, 3, 4]
        XCTAssertEqual(
            QueueMoveMath.targetQueueIndex(rowQueueIndices: rows, to: 1, currentQueueIndex: 2),
            3
        )
    }

    /// Trailing chapter rows have no following track, so the answer comes from scanning back.
    func testDropAfterTrailingChaptersResolvesFromThePrecedingTrack() {
        let rows: [Int?] = [0, 1, nil, nil]
        XCTAssertEqual(
            QueueMoveMath.targetQueueIndex(rowQueueIndices: rows, to: 4, currentQueueIndex: 2),
            2
        )
    }

    /// A queue of nothing but chapter rows — nothing is draggable, but the arithmetic must not
    /// trap on the empty slices.
    func testAllChapterRowsFallsBackToJustAfterTheCurrentItem() {
        XCTAssertEqual(
            QueueMoveMath.targetQueueIndex(rowQueueIndices: [nil, nil], to: 1, currentQueueIndex: 7),
            8
        )
        XCTAssertEqual(
            QueueMoveMath.targetQueueIndex(rowQueueIndices: [nil, nil], to: 1, currentQueueIndex: nil),
            0
        )
    }

    // MARK: - Invalid input

    func testDraggingAChapterRowIsRejected() {
        XCTAssertNil(
            QueueMoveMath.resolve(rowQueueIndices: [0, nil, 2], from: 1, to: 0, currentQueueIndex: nil),
            "chapters aren't draggable; a chapter source must not resolve to a move"
        )
    }

    func testOutOfRangeSourceIsRejected() {
        XCTAssertNil(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 99, to: 0, currentQueueIndex: nil)
        )
    }

    func testEmptyQueueIsRejected() {
        XCTAssertNil(
            QueueMoveMath.resolve(rowQueueIndices: [], from: 0, to: 0, currentQueueIndex: nil)
        )
    }

    /// A move that resolves to where the item already is stays a no-op rather than a rejection —
    /// the caller applies it harmlessly, and treating it as invalid would be a lie about why.
    func testMoveOntoItsOwnPositionResolvesToItself() throws {
        let move = try XCTUnwrap(
            QueueMoveMath.resolve(rowQueueIndices: plainRows, from: 2, to: 2, currentQueueIndex: nil)
        )
        XCTAssertEqual(move.fromQueueIndex, 2)
        XCTAssertEqual(move.serverToIndex, 2)
    }
}
