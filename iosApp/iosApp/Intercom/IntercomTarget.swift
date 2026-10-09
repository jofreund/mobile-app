import Foundation

/// One card on the intercom grid: a Music Assistant player that can take a
/// spoken announcement. home-intercom's `Room`, with the player list in place
/// of Home Assistant's room configuration.
///
/// Pure value, so the view model and its tests never see Kotlin; the view
/// builds these from `PlayerBarStore.players`. Every player there is
/// available, enabled and visible — the kernel drops the rest — so there is no
/// offline card to draw, unlike a room whose speaker had gone away.
struct IntercomTarget: Identifiable, Hashable, Sendable {
    /// The player id — what the announcement is sent to.
    let id: String
    let name: String
    /// The shared-icon-set id `PlayerIcon` draws.
    let iconId: String
    /// An announcement is playing on this player right now.
    let isAnnouncing: Bool
}
