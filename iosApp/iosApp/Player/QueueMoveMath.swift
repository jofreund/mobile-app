import Foundation

/// The index arithmetic behind a queue drag, pulled out of `ExpandedPlayerView` so it can be
/// tested. Three separate bugs shipped in this logic before it had any coverage, and all three
/// were arithmetic or guard mistakes rather than UI ones — nothing here needs a view to exercise.
///
/// Deliberately free of Kotlin types: rows arrive as `[Int?]` (a `.track` row's queue index, or
/// `nil` for a chapter row). That keeps it honest about what actually matters, and it's also a
/// hard requirement — `iosAppTests` has no `FRAMEWORK_SEARCH_PATHS`, so a file importing
/// `MusicAssistantKit` can't be compiled into the test target at all.
///
/// Three coordinate systems meet here, which is why this kept going wrong:
///
/// 1. **Display index** — a position in the flattened rows, which omit the current item's own
///    track row and interleave its chapters.
/// 2. **Queue index** — the item's absolute position in the queue.
/// 3. **`pos_shift`** — what the server wants, measured *after* the source item is removed.
enum QueueMoveMath {

    struct Move: Equatable {
        let fromQueueIndex: Int

        /// Pre-removal insertion offset — the convention `Array.move(fromOffsets:toOffset:)` and
        /// SwiftUI's `.onMove` use, for the optimistic local reorder.
        let localToIndex: Int

        /// Post-removal index, for the server. Mirrors Compose's
        /// `add(toQueueIndex, removeAt(fromQueueIndex))`, where removing the source first shifts
        /// everything after it down by one.
        let serverToIndex: Int
    }

    /// Resolves a drag into the move to apply and dispatch, or `nil` when it should be dropped.
    ///
    /// - Parameters:
    ///   - rowQueueIndices: one entry per display row — the queue index of a `.track` row, `nil`
    ///     for a chapter row.
    ///   - from: display index being dragged.
    ///   - to: SwiftUI's drop offset, in `0...rowQueueIndices.count`.
    ///   - currentQueueIndex: queue index of the playing item, or `nil` when nothing is playing.
    static func resolve(
        rowQueueIndices: [Int?],
        from: Int,
        to: Int,
        currentQueueIndex: Int?
    ) -> Move? {
        guard rowQueueIndices.indices.contains(from),
              let fromQueueIndex = rowQueueIndices[from]
        else { return nil }

        let toQueueIndex = targetQueueIndex(
            rowQueueIndices: rowQueueIndices,
            to: to,
            currentQueueIndex: currentQueueIndex
        )

        // Dropping at or before the playing item is rejected. A queue with *no* current item
        // imposes no such floor — Compose spells that out as
        // `currentIdx >= 0 && toQueueIndex <= currentIdx`. Requiring a current item here (an
        // earlier version did) silently discarded every reorder in a loaded-but-idle queue,
        // where nothing is playing so every row is draggable and every drag was thrown away.
        if let currentQueueIndex, toQueueIndex <= currentQueueIndex { return nil }

        // Forward moves are the only direction reachable (backward past the current item is
        // rejected above), and they're exactly the ones the post-removal shift applies to.
        // Sending the unadjusted index overshoots by one on every forward drag: the reorder
        // looked right locally and landed one position off on the server.
        let serverToIndex = toQueueIndex > fromQueueIndex ? toQueueIndex - 1 : toQueueIndex

        return Move(
            fromQueueIndex: fromQueueIndex,
            localToIndex: toQueueIndex,
            serverToIndex: serverToIndex
        )
    }

    /// Maps a display drop position to an absolute queue index by reading the queue index stored
    /// on the nearest surrounding `.track` row.
    ///
    /// Reading it rather than counting rows is the point. Counting undercounts by exactly the
    /// number of omitted current-item rows before `to`, which is what broke every reorder once
    /// the current item's own row stopped being rendered.
    static func targetQueueIndex(
        rowQueueIndices: [Int?],
        to: Int,
        currentQueueIndex: Int?
    ) -> Int {
        // Nearest track at or after the drop point: insert before it.
        for index in rowQueueIndices.indices where index >= to {
            if let queueIndex = rowQueueIndices[index] { return queueIndex }
        }
        // Dropped past the last track: insert after the nearest track before it.
        for index in rowQueueIndices.indices.reversed() where index < to {
            if let queueIndex = rowQueueIndices[index] { return queueIndex + 1 }
        }
        // No track rows at all (a queue of nothing but chapters), where nothing is draggable
        // anyway. Just after the current item, or the front of an idle queue.
        return (currentQueueIndex ?? -1) + 1
    }
}
