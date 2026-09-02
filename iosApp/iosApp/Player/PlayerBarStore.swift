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

    /// The selected player's id, or nil while the list is empty (or the index is momentarily out
    /// of range against a freshly shortened list). What "which player is this" questions ask,
    /// rather than making each caller re-check the index against the list.
    var selectedPlayerID: String? {
        players.indices.contains(selectedIndex) ? players[selectedIndex].id : nil
    }

    /// The chapter the selected player's scrubber presents, or nil for absolute time. Kotlin
    /// re-publishes this at each chapter boundary — nothing else announces the change — and
    /// resolves it to nil when the book has no chapters or the server preference is off.
    private(set) var presentationChapter: ChapterBarItem?

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

    /// Seeks to a position read off a chapter-relative scrubber, returning the absolute
    /// position actually requested so the caller can latch it.
    ///
    /// `chapter` is the one latched when the drag began, not `presentationChapter` as it
    /// stands now: crossing a boundary mid-drag must not re-base the released value.
    func seekWithinChapter(id: String, chapter: ChapterBarItem, relativeSeconds: Double) -> Double {
        KmpHelper.shared.seekWithinChapter(
            playerId: id,
            chapter: chapter,
            relativeSec: relativeSeconds
        )
    }

    /// Relative seek behind the spoken-word skip buttons. Kotlin resolves the offset against
    /// the live position at send time (`KmpHelper.seekPlayerBarBy`) — a position computed here
    /// off the interpolated ticker would drift from where the player actually is.
    func seekBy(id: String, seconds: Int) {
        KmpHelper.shared.seekPlayerBarBy(playerId: id, seconds: Int64(seconds))
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

    /// Optimistic — the heart flips on the next state emission via Kotlin's favorite
    /// override, rolls back on send failure. See `KmpHelper.toggleFavoriteOptimistic`.
    func toggleFavorite(item: AppMediaItem) {
        KmpHelper.shared.toggleFavoriteOptimistic(item: item)
    }

    func setSleepTimer(id: String, seconds: Int) {
        KmpHelper.shared.setPlayerSleepTimer(playerId: id, seconds: Int32(seconds))
    }

    func clearSleepTimer(id: String) {
        KmpHelper.shared.clearPlayerSleepTimer(playerId: id)
    }

    func playQueueItem(queueId: String, queueItemId: String) {
        KmpHelper.shared.playQueueItem(queueId: queueId, queueItemId: queueItemId)
    }

    func moveQueueItem(queueId: String, queueItemId: String, from: Int, to: Int) {
        KmpHelper.shared.moveQueueItem(queueId: queueId, queueItemId: queueItemId, from: Int32(from), to: Int32(to))
    }

    /// Hands `sourceQueueId`'s whole queue to `targetQueueId`. `autoplay` is the server's
    /// `auto_play`: pass whether the source was playing, so a paused queue arrives paused.
    func transferQueue(sourceQueueId: String, targetQueueId: String, autoplay: Bool) {
        KmpHelper.shared.transferQueue(
            sourceQueueId: sourceQueueId,
            targetQueueId: targetQueueId,
            autoplay: autoplay
        )
    }

    /// Both take the value as it stands and let Kotlin compute the flip, same as
    /// `toggleShuffle`/`cycleRepeatMode`. No optimistic state: the server echoes a queue
    /// update and `playerBarState` re-projects.
    func toggleAutoplay(id: String, isEnabledNow: Bool) {
        KmpHelper.shared.togglePlayerBarAutoplay(playerId: id, isEnabledNow: isEnabledNow)
    }

    func toggleCrossfade(id: String, isEnabledNow: Bool) {
        KmpHelper.shared.togglePlayerBarCrossfade(playerId: id, isEnabledNow: isEnabledNow)
    }

    /// Sends the chosen speed as-is; no flip to compute, and no optimistic echo either — the
    /// menu's checkmark moves when the server confirms through `playerBarState`.
    func setPlaybackSpeed(id: String, speed: Double) {
        KmpHelper.shared.setPlayerBarPlaybackSpeed(playerId: id, speed: speed)
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
            presentationChapter = nil
            queueViewCache = [:]
            return
        }
        var freshCache: [String: QueueViewCacheEntry] = [:]
        players = data.players.map { item in
            let projected = projectQueueItems(of: item)
            freshCache[item.playerId] = QueueViewCacheEntry(
                source: item.queueItems,
                projected: projected
            )
            return PlayerBarItemView(item, queueItems: projected)
        }
        // Replaced wholesale, so players that disappeared drop their cached queues with them.
        queueViewCache = freshCache
        selectedIndex = Int(data.selectedIndex)
        presentationChapter = data.presentationChapter
    }

    /// Swift half of Kotlin's `QueueProjectionCache`: reuse the previous `QueueBarItemView`s
    /// when the source rows are the very same Kotlin objects as last time.
    ///
    /// Every emission used to rebuild a `QueueBarItemView` — `URL(string:)` parse included —
    /// for every queue item of every player, on the main thread, even though almost every
    /// emission changes something *else* (a play-state flip, a volume echo). The Kotlin side
    /// already returns the identical projected list instance across such rebuilds, so its rows
    /// keep their object identity across the bridge, and an element-wise `===` walk (cheap
    /// pointer compares) is enough to know the old projection is still exact. Any mismatch —
    /// count, order, or a genuinely new row — falls through to a full re-projection, so a miss
    /// is only ever a missed optimization, same contract as the Kotlin cache.
    private func projectQueueItems(of item: PlayerBarItem) -> [QueueBarItemView] {
        let source = item.queueItems
        if let cached = queueViewCache[item.playerId],
           cached.source.count == source.count,
           zip(cached.source, source).allSatisfy({ $0 === $1 }) {
            return cached.projected
        }
        return source.map(QueueBarItemView.init)
    }

    private struct QueueViewCacheEntry {
        let source: [QueueBarItem]
        let projected: [QueueBarItemView]
    }

    private var queueViewCache: [String: QueueViewCacheEntry] = [:]
}

/// SwiftUI-shaped projection of the Kotlin `PlayerBarItem` — same "flatten at the bridge
/// boundary" pattern `MediaItem` uses over `AppMediaItem`. Read by both `MiniPlayerView`
/// (first eight fields only) and `ExpandedPlayerView` (everything).
struct PlayerBarItemView: Identifiable {
    let id: String
    let name: String
    /// The icon the server has for this player, unresolved — a shared-icon-set id
    /// ("sonos") on a current server, a Material Design Icons name ("mdi-speaker")
    /// on an older one. See `iconId`.
    let icon: String?
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
    /// "Autoplay" — what the server used to call "don't stop the music". Drives the overflow
    /// menu's first toggle.
    let autoplayEnabled: Bool
    /// Only meaningful while `crossfadeSupported`; false otherwise.
    let crossfadeEnabled: Bool
    /// The server reported `crossfade_enabled` for this queue. Older servers don't, and the
    /// Crossfade row is left out of the menu entirely rather than drawn dead.
    let crossfadeSupported: Bool
    /// The queue's speed (1.0 = normal), nil when the server reports none — then there is no
    /// speed row to draw. See `PlaybackSpeedOptions` for how the value becomes menu rows.
    let playbackSpeed: Double?
    let volumeLevel: Float?
    let isMuted: Bool
    let canMute: Bool
    /// Unix (UTC) seconds at which the server's sleep timer stops playback, nil when no timer
    /// runs. A static expiry — the ticking countdown is derived at render time (`TimelineView`).
    let sleepTimerExpiresAt: Double?
    /// The current queue track — kept as the real Kotlin type (not flattened further) so
    /// `ExpandedPlayerView` can read `.favorite`/`.uri` directly and pass it whole to
    /// `KmpHelper.toggleFavoriteOptimistic` instead of adding favorite-specific fields here.
    let trackItem: AppMediaItem?
    /// What `KmpHelper.playQueueItem`/`moveQueueItem`/`removeQueueItem` key on — nil when this
    /// player has no queue at all.
    let queueId: String?
    let queueItems: [QueueBarItemView]
    let currentQueueItemId: String?
    /// Non-empty only when the current queue item is an audiobook — mirrors
    /// `QueueDisplayRows.kt`'s chapter-nesting rule.
    let currentItemChapters: [Chapter]
    /// The current item is an audiobook or a podcast episode. Swaps the expanded player's
    /// shuffle/repeat buttons for skip-back/skip-forward — see `ExpandedPlayerView.transportRow`.
    let isSpokenWord: Bool
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

    /// [queueItems] is supplied pre-projected by `PlayerBarStore`, which caches the previous
    /// projection and reuses it when the underlying Kotlin rows are identical — see
    /// `PlayerBarStore.projectQueueItems`.
    init(_ item: PlayerBarItem, queueItems: [QueueBarItemView]) {
        self.id = item.playerId
        self.name = item.name
        self.icon = item.icon
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
        self.autoplayEnabled = item.autoplayEnabled
        self.crossfadeEnabled = item.crossfadeEnabled
        self.crossfadeSupported = item.crossfadeSupported
        self.playbackSpeed = item.playbackSpeed?.doubleValue
        self.volumeLevel = item.volumeLevel?.floatValue
        self.isMuted = item.isMuted
        self.canMute = item.canMute
        self.sleepTimerExpiresAt = item.sleepTimerExpiresAt?.doubleValue
        self.trackItem = item.trackItem
        self.queueId = item.queueId
        self.queueItems = queueItems
        self.currentQueueItemId = item.currentQueueItemId
        self.currentItemChapters = item.currentItemChapters
        self.isSpokenWord = item.isSpokenWord
        self.isGroup = item.isGroup
        self.isGrouped = item.isGrouped
        self.groupVolume = item.groupVolume?.floatValue
        self.groupVolumeMuted = item.groupVolumeMuted
        self.ownVolume = item.ownVolume?.floatValue
        self.ownVolumeMuted = item.ownVolumeMuted
        self.volumeSliderAccessible = item.volumeSliderAccessible
        self.groupMembers = item.groupMembers.map(GroupMemberBarItemView.init)
    }

    /// The shared-icon-set id to draw for this player — see `PlayerIcon`, which
    /// resolves the server's raw value and owns the artwork.
    var iconId: String { PlayerIcon.resolve(icon, isGroup: isGroup) }
}

/// `id`, `queueId` and `canPlay` are already exactly what the transfer filter asks for, so the
/// conformance is empty. It lives here rather than in `TransferQueueTargets.swift` because that
/// file is compiled into the test target too, where this type — and the Kotlin framework behind
/// it — isn't available.
extension PlayerBarItemView: TransferQueueCandidate {}

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
