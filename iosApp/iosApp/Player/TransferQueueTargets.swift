import Foundation

/// What `TransferQueueTargets` needs to know about a player to judge it as a destination.
///
/// A protocol rather than `PlayerBarItemView` itself so the rule below compiles — and is
/// tested — without the Kotlin framework, the same way every other unit-tested file here
/// (`QueueMoveMath`, `SearchSections`, `LibraryListReconciler`) stays free of it.
/// `PlayerBarItemView` conforms in `PlayerBarStore.swift`; its `id`, `queueId` and `canPlay`
/// already match.
protocol TransferQueueCandidate {
    var id: String { get }
    var queueId: String? { get }
    var canPlay: Bool { get }
}

/// Which players a queue can be handed to — the rule behind `TransferQueueSheet`'s list, kept
/// out of the view so it can be tested on its own (same split as `QueueMoveMath`).
enum TransferQueueTargets {

    /// Candidates for `source`'s queue, in the order `PlayerBarStore` already holds them —
    /// which is the player sorting the user configured. Deliberately not re-sorted: a list that
    /// reorders itself between the player picker and this sheet reads as a different set of
    /// speakers.
    ///
    /// Excluded: the source itself; a player with no queue to receive into; and one that cannot
    /// play right now (`canPlay` is what the transport buttons gate on — an announcing or
    /// otherwise unavailable player would swallow the queue).
    ///
    /// Deliberately *not* excluded: powered-off players, which the server powers on when a
    /// queue starts on them — the player picker already lists them on the same assumption —
    /// and groups, which carry a queue of their own and are a normal destination.
    static func candidates<Candidate: TransferQueueCandidate>(
        from players: [Candidate],
        source: Candidate
    ) -> [Candidate] {
        players.filter { candidate in
            candidate.id != source.id && candidate.queueId != nil && candidate.canPlay
        }
    }
}
