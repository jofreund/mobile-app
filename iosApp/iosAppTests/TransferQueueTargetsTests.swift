import XCTest

/// Pins which players `TransferQueueSheet` offers as destinations. The rule lives in a pure
/// function precisely so it can be checked here rather than by opening a sheet on a device with
/// the right five speakers on the network.
///
/// Three exclusions, an ordering guarantee, and — see the note further down — two *inclusions*
/// that a stricter-looks-safer rewrite would quietly break.
final class TransferQueueTargetsTests: XCTestCase {

    /// Stands in for `PlayerBarItemView`, which needs the Kotlin framework. Same shape the
    /// filter sees; every other unit test here fakes its input the same way.
    private struct TestPlayer: TransferQueueCandidate {
        let id: String
        var queueId: String?
        var canPlay = true

        init(_ id: String, queueId: String? = nil, canPlay: Bool = true) {
            self.id = id
            // A real player's queue id defaults to its own id — `PlayerData.queueOrPlayerId`.
            self.queueId = queueId ?? id
            self.canPlay = canPlay
        }

        /// A player the server reports without any queue at all.
        static func withoutQueue(_ id: String) -> TestPlayer {
            var player = TestPlayer(id)
            player.queueId = nil
            return player
        }
    }

    // MARK: - Exclusions

    func testTheSourceIsNeverItsOwnTarget() {
        let source = TestPlayer("a")

        let candidates = TransferQueueTargets.candidates(from: [source, TestPlayer("b")], source: source)

        XCTAssertEqual(candidates.map(\.id), ["b"])
    }

    /// `queueId` is nil only for a player with no queue at all — there is nothing for a
    /// transferred queue to land in, and the transfer call itself is addressed by queue id.
    func testAPlayerWithNoQueueIsNotATarget() {
        let candidates = TransferQueueTargets.candidates(
            from: [TestPlayer("a"), .withoutQueue("b")],
            source: TestPlayer("source")
        )

        XCTAssertEqual(candidates.map(\.id), ["a"])
    }

    /// The same gate the transport buttons use: an announcing or otherwise unavailable player
    /// would accept the queue and swallow it.
    func testAPlayerThatCannotPlayIsNotATarget() {
        let candidates = TransferQueueTargets.candidates(
            from: [TestPlayer("a"), TestPlayer("b", canPlay: false)],
            source: TestPlayer("source")
        )

        XCTAssertEqual(candidates.map(\.id), ["a"])
    }

    func testTheOnlyPlayerOnTheNetworkLeavesNothingToOffer() {
        let source = TestPlayer("a")

        XCTAssertTrue(TransferQueueTargets.candidates(from: [source], source: source).isEmpty)
    }

    // MARK: - Ordering

    /// The store's order is the player sorting the user configured. Sorting here — by name, or
    /// by what is playing — would show the same speakers in a different order than the picker
    /// two taps earlier.
    func testOrderFollowsTheStoreRatherThanBeingReSorted() {
        let candidates = TransferQueueTargets.candidates(
            from: [TestPlayer("zulu"), TestPlayer("alpha"), TestPlayer("mike")],
            source: TestPlayer("source")
        )

        XCTAssertEqual(candidates.map(\.id), ["zulu", "alpha", "mike"])
    }

    // MARK: - Deliberate inclusions
    //
    // Powered-off players and groups are both valid destinations — the server powers a player
    // on when a queue starts on it (the player picker lists them on that same assumption), and
    // a group carries a queue of its own, which is half of what the feature is for. That is
    // enforced structurally rather than by a case here: `TransferQueueCandidate` exposes id,
    // queueId and canPlay and nothing else, so neither power nor group membership is visible to
    // the filter. Adding a case for them means widening the protocol, which is the moment to
    // re-read this note.

    func testEveryOtherPlayableQueueBearingPlayerSurvives() {
        let players = [TestPlayer("a"), TestPlayer("b"), TestPlayer("c")]

        let candidates = TransferQueueTargets.candidates(from: players, source: TestPlayer("source"))

        XCTAssertEqual(candidates.map(\.id), ["a", "b", "c"])
    }
}
