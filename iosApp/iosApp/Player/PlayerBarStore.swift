import SwiftUI
import MusicAssistantKit

/// Drives the native mini player (`MiniPlayerView.swift`) — subscribes to
/// `KmpHelper.playerBarState` and turns transport taps into `KmpHelper` calls. All real state
/// (which players are connected, which is selected, local-vs-remote command routing/optimistic
/// dispatch) stays in `MainDataSource`; this is a thin Kotlin-to-SwiftUI projection, same shape
/// as `ConnectionSetupStore`.
///
/// One shared instance, owned by `AppTabView` and passed to all three tabs — unlike the Compose
/// original, which re-subscribed and re-derived pager state once per tab (three competing
/// `HomeScreenViewModel`/`rememberPagerState` instances). The player list and selection are
/// identical across tabs, so one native subscription replaces three redundant Kotlin ones.
@Observable
@MainActor
final class PlayerBarStore {

    private(set) var players: [PlayerBarItemView] = []
    private(set) var selectedIndex: Int = 0

    private var stateSub: Cancellable?

    func start() {
        guard stateSub == nil else { return }
        stateSub = KmpHelper.shared.playerBarState.subscribe { [weak self] state in
            self?.handle(state)
        }
    }

    func stop() {
        stateSub?.cancel()
        stateSub = nil
    }

    func selectPlayer(id: String) {
        KmpHelper.shared.selectPlayerBarPlayer(playerId: id)
    }

    func togglePlayPause(id: String) {
        KmpHelper.shared.togglePlayerBarPlayPause(playerId: id)
    }

    func skipNext(id: String) {
        KmpHelper.shared.skipPlayerBarNext(playerId: id)
    }

    func skipPrevious(id: String) {
        KmpHelper.shared.skipPlayerBarPrevious(playerId: id)
    }

    func seek(id: String, seconds: Double) {
        KmpHelper.shared.seekPlayerBar(playerId: id, seconds: seconds)
    }

    func toggleShuffle(id: String) {
        KmpHelper.shared.togglePlayerBarShuffle(playerId: id)
    }

    func cycleRepeatMode(id: String) {
        KmpHelper.shared.cyclePlayerBarRepeatMode(playerId: id)
    }

    func toggleMute(id: String) {
        KmpHelper.shared.togglePlayerBarMute(playerId: id)
    }

    func setVolume(id: String, level: Float) {
        KmpHelper.shared.setPlayerBarVolume(playerId: id, level: level)
    }

    func playQueueItem(queueId: String, queueItemId: String) {
        KmpHelper.shared.playQueueItem(queueId: queueId, queueItemId: queueItemId)
    }

    func moveQueueItem(queueId: String, queueItemId: String, from: Int, to: Int) {
        KmpHelper.shared.moveQueueItem(queueId: queueId, queueItemId: queueItemId, from: Int32(from), to: Int32(to))
    }

    func addGroupMember(parentId: String, childId: String) {
        KmpHelper.shared.addGroupMember(parentId: parentId, childId: childId)
    }

    func removeGroupMember(parentId: String, childId: String) {
        KmpHelper.shared.removeGroupMember(parentId: parentId, childId: childId)
    }

    func setGroupVolume(id: String, level: Float) {
        KmpHelper.shared.setGroupVolume(playerId: id, level: level)
    }

    func toggleGroupMute(id: String, isMutedNow: Bool) {
        KmpHelper.shared.toggleGroupMute(playerId: id, isMutedNow: isMutedNow)
    }

    func setMemberVolume(id: String, level: Float) {
        KmpHelper.shared.setMemberVolume(playerId: id, level: level)
    }

    func toggleMemberMute(id: String, isMutedNow: Bool) {
        KmpHelper.shared.toggleMemberMute(playerId: id, isMutedNow: isMutedNow)
    }

    private func handle(_ state: PlayerBarState?) {
        guard let data = state as? PlayerBarState.Data else {
            players = []
            selectedIndex = 0
            return
        }
        players = data.players.map(PlayerBarItemView.init)
        selectedIndex = Int(data.selectedIndex)
    }
}

/// SwiftUI-shaped projection of the Kotlin `PlayerBarItem` — same "flatten at the bridge
/// boundary" pattern `MediaItem` uses over `AppMediaItem`. Read by both `MiniPlayerView`
/// (first eight fields only) and `ExpandedPlayerView` (everything).
struct PlayerBarItemView: Identifiable {
    let id: String
    let name: String
    let isPlaying: Bool
    let isPoweredOff: Bool
    let title: String?
    let subtitle: String?
    let artworkURL: URL?
    let canPlay: Bool
    let duration: Double?
    let elapsedTime: Double?
    let shuffleEnabled: Bool
    let repeatMode: RepeatMode?
    let isDynamicPlaylist: Bool
    let volumeLevel: Float?
    let isMuted: Bool
    let canMute: Bool
    /// The current queue track — kept as the real Kotlin type (not flattened further) so
    /// `ExpandedPlayerView` can read `.favorite`/`.uri` directly and reuse the existing
    /// `KmpHelper.setFavorite(item:favorite:)` bridge instead of adding a favorite-specific one.
    let trackItem: AppMediaItem?
    /// What `KmpHelper.playQueueItem`/`moveQueueItem`/`removeQueueItem` key on — nil when this
    /// player has no queue at all.
    let queueId: String?
    let queueItems: [QueueBarItemView]
    let currentQueueItemId: String?
    /// Non-empty only when the current queue item is an audiobook — mirrors
    /// `QueueDisplayRows.kt`'s chapter-nesting rule.
    let currentItemChapters: [Chapter]
    /// `PlayerType.GROUP` — the group-settings pivot row drives group volume, not its own.
    let isGroup: Bool
    /// Sync-group leader with members — shows the extra group-volume row in group settings.
    let isGrouped: Bool
    let groupVolume: Float?
    let groupVolumeMuted: Bool
    /// Raw own volume/mute (not group-adjusted like `volumeLevel`) — the group-settings pivot row.
    let ownVolume: Float?
    let ownVolumeMuted: Bool
    let volumeSliderAccessible: Bool
    /// Bound members + groupable candidates, bound-first. Non-empty (or `isGrouped`) is what
    /// makes the expanded player's group-settings header icon appear at all.
    let groupMembers: [GroupMemberBarItemView]

    init(_ item: PlayerBarItem) {
        self.id = item.playerId
        self.name = item.name
        self.isPlaying = item.isPlaying
        self.isPoweredOff = item.isPoweredOff
        self.title = item.title
        self.subtitle = item.subtitle
        self.artworkURL = item.artworkUrl.flatMap { URL(string: $0) }
        self.canPlay = item.canPlay
        self.duration = item.duration?.doubleValue
        self.elapsedTime = item.elapsedTime?.doubleValue
        self.shuffleEnabled = item.shuffleEnabled
        self.repeatMode = item.repeatMode
        self.isDynamicPlaylist = item.isDynamicPlaylist
        self.volumeLevel = item.volumeLevel?.floatValue
        self.isMuted = item.isMuted
        self.canMute = item.canMute
        self.trackItem = item.trackItem
        self.queueId = item.queueId
        self.queueItems = item.queueItems.map(QueueBarItemView.init)
        self.currentQueueItemId = item.currentQueueItemId
        self.currentItemChapters = item.currentItemChapters
        self.isGroup = item.isGroup
        self.isGrouped = item.isGrouped
        self.groupVolume = item.groupVolume?.floatValue
        self.groupVolumeMuted = item.groupVolumeMuted
        self.ownVolume = item.ownVolume?.floatValue
        self.ownVolumeMuted = item.ownVolumeMuted
        self.volumeSliderAccessible = item.volumeSliderAccessible
        self.groupMembers = item.groupMembers.map(GroupMemberBarItemView.init)
    }
}

/// SwiftUI-shaped projection of the Kotlin `GroupMemberBarItem` — one row in the group
/// settings sheet (a bound member or a groupable candidate).
struct GroupMemberBarItemView: Identifiable {
    let id: String
    let name: String
    let volume: Float?
    let volumeSliderAccessible: Bool
    let isMuted: Bool
    let canMute: Bool
    let isBound: Bool
    let isManageable: Bool

    init(_ item: GroupMemberBarItem) {
        self.id = item.id
        self.name = item.name
        self.volume = item.volume?.floatValue
        self.volumeSliderAccessible = item.volumeSliderAccessible
        self.isMuted = item.isMuted
        self.canMute = item.canMute
        self.isBound = item.isBound
        self.isManageable = item.isManageable
    }
}

/// SwiftUI-shaped projection of the Kotlin `QueueBarItem` — one queue row.
struct QueueBarItemView: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let isPlayable: Bool
    let trackItem: AppMediaItem?

    init(_ item: QueueBarItem) {
        self.id = item.id
        self.title = item.title
        self.subtitle = item.subtitle
        self.artworkURL = item.artworkUrl.flatMap { URL(string: $0) }
        self.isPlayable = item.isPlayable
        self.trackItem = item.trackItem
    }
}

// Deliberately NOT Equatable. An id-only `==` (which is all this could offer — `trackItem` is a
// bridged Kotlin class Swift can't compare) reads as "these two players are the same" to
// SwiftUI's view-value diffing, which uses stored properties' Equatable conformance to decide
// whether to skip re-running a body. Every state change here keeps the same id, so that `==`
// told SwiftUI "nothing changed" on literally every update. Without the conformance SwiftUI
// can't prove equality and re-renders, which is the correct default for a value whose contents
// change constantly. Nothing in the app compares these directly.
