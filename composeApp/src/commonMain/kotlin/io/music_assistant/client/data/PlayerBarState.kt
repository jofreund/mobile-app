package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.Chapter
import io.music_assistant.client.data.model.client.ImageType
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.QueueTrack
import io.music_assistant.client.data.model.client.RepeatMode
import io.music_assistant.client.data.model.client.items.AppMediaItem
import io.music_assistant.client.data.model.client.items.Audiobook
import io.music_assistant.client.data.model.client.items.PodcastEpisode
import io.music_assistant.client.ui.compose.common.DataState

/**
 * Flat, Swift-bridgeable projection of [PlayerData] for the native mini and expanded player —
 * mirrors the "flatten at the bridge boundary" pattern `MediaItem` uses over
 * `AppMediaItem`, rather than exporting `Player`/`PlayerData`/`PlayerMedia` directly. One shape
 * for both: the mini player only reads the first eight fields, the expanded player also reads
 * the rest (duration/elapsedTime/shuffle/repeat/volume/trackItem) — mirrors Compose's own
 * `PlayersPager`, which shares one `HorizontalPager`/state for both collapsed and expanded.
 */
data class PlayerBarItem(
    val playerId: String,
    val name: String,
    /**
     * The server's own icon for this player, as a Material Design Icons name ("mdi-speaker",
     * "mdi-cast"). Passed through unmapped: what an `mdi-` name should look like is a platform
     * question, and Swift answers it in `PlayerBarItemView.symbolName`.
     */
    val icon: String?,
    val isPlaying: Boolean,
    val isPoweredOff: Boolean,
    val title: String?,
    val subtitle: String?,
    val artworkUrl: String?,
    /** `player.canPlay && !player.isAnnouncing` — gates the expanded view's transport buttons. */
    val canPlay: Boolean,
    val duration: Double?,
    /** Snapshot only — the expanded player's ticking position comes from `observePlayerBarPosition`. */
    val elapsedTime: Double?,
    val shuffleEnabled: Boolean,
    val repeatMode: RepeatMode?,
    /** Disables shuffle/repeat in the expanded view, same as Compose. */
    val isDynamicPlaylist: Boolean,
    /** Null when the player has no accessible volume control (mirrors `isVolumeSliderAccessible`). */
    val volumeLevel: Float?,
    val isMuted: Boolean,
    val canMute: Boolean,
    /** Unix (UTC) seconds at which the server stops playback, or null when no timer runs.
     * A static expiry, not a countdown — the ticking display is Swift's job, so this only
     * changes on set/clear and stays cheap for [playerBarStatesEquivalentIgnoringElapsed]. */
    val sleepTimerExpiresAt: Double?,
    /** The current queue track, exposed whole so Swift can read `favorite`/`uri` directly and
     * pass it to `toggleFavoriteOptimistic` instead of adding separate favorite fields here. */
    val trackItem: AppMediaItem?,
    /** What queue actions (`playQueueItem`/`moveQueueItem`/`removeQueueItem`) key on — null when
     * this player has no queue at all. */
    val queueId: String?,
    val queueItems: List<QueueBarItem>,
    val currentQueueItemId: String?,
    /** Only ever non-empty for the *currently playing* item, and only when it's an [Audiobook] —
     * mirrors `QueueDisplayRows.kt`'s chapter-nesting rule exactly. */
    val currentItemChapters: List<Chapter>,
    /**
     * True when the current item is spoken word — an [Audiobook] or a [PodcastEpisode].
     *
     * Swapping shuffle/repeat for the skip-back/skip-forward pair is the only thing that reads
     * it: on a six-hour book or an hour-long episode, shuffling the queue or repeating the item
     * is meaningless, while nudging past an ad break or back over a missed sentence is the
     * control you actually reach for. False for anything else, including a null track, so a
     * player between items keeps the music transport it had.
     */
    val isSpokenWord: Boolean,
    /** `PlayerType.GROUP` — the pivot card in group settings drives group volume, not its own. */
    val isGroup: Boolean,
    /** A non-GROUP player currently leading a sync group — shows the extra group-volume row. */
    val isGrouped: Boolean,
    val groupVolume: Float?,
    val groupVolumeMuted: Boolean,
    /** The player's RAW own volume/mute (`player.volumeLevel`/`volumeMuted`) — unlike
     * [volumeLevel] above, which is `currentVolume` (group volume while grouped). The group
     * settings pivot row shows the player's own level, exactly like Compose's dialog did. */
    val ownVolume: Float?,
    val ownVolumeMuted: Boolean,
    /** `player.isVolumeSliderAccessible` — the pivot row's enabled gate in group settings. */
    val volumeSliderAccessible: Boolean,
    /** Bound members and groupable candidates, bound-first — from [PlayerData.childrenBinds]. */
    val groupMembers: List<GroupMemberBarItem>,
)

/**
 * Flat, Swift-bridgeable projection of [PlayerData.ChildBind] — one row in the native group
 * settings sheet. [canMute] flattens ChildBind's nullable `isMuted` (null = no mute control)
 * so Swift never sees a `KotlinBoolean?`.
 */
data class GroupMemberBarItem(
    val id: String,
    val name: String,
    val volume: Float?,
    val volumeSliderAccessible: Boolean,
    val isMuted: Boolean,
    val canMute: Boolean,
    val isBound: Boolean,
    /** False for static group members — the server won't let them be removed. */
    val isManageable: Boolean,
)

/**
 * Flat, Swift-bridgeable projection of a single `QueueTrack` — same "flatten at the boundary"
 * pattern as [PlayerBarItem] itself. Carries the full [trackItem] (not just title/subtitle/
 * artwork) so the native queue row can reuse `ItemContextMenu.swift`'s `.itemContextMenu()`
 * wholesale instead of a queue-specific menu.
 */
data class QueueBarItem(
    val id: String,
    val title: String,
    val subtitle: String?,
    val artworkUrl: String?,
    val isPlayable: Boolean,
    val trackItem: AppMediaItem?,
)

/**
 * Flat, Swift-bridgeable projection of a [io.music_assistant.client.data.model.client.ResolvedChapter].
 *
 * Only the selected player gets one — it is the only player with a scrubber on screen — so it
 * hangs off [PlayerBarState.Data] rather than off every [PlayerBarItem].
 *
 * [startSec] and [durationSec] are the whole coordinate frame Swift needs: the slider spans
 * `0...durationSec`, and a released drag goes back through
 * [io.music_assistant.client.di.KmpHelper.seekWithinChapter] rather than being converted in
 * Swift, so the rounding rule stays in one place.
 */
data class ChapterBarItem(
    /** Null when the metadata ships a blank name; Swift falls back to the album/author line. */
    val name: String?,
    val startSec: Double,
    val durationSec: Double,
)

sealed class PlayerBarState {
    data object Loading : PlayerBarState()
    data object Empty : PlayerBarState()
    data class Data(
        val players: List<PlayerBarItem>,
        val selectedIndex: Int,
        /**
         * The chapter the selected player's scrubber presents, or null for absolute time —
         * no chapters, not an audiobook, or the server preference is off.
         */
        val presentationChapter: ChapterBarItem? = null,
    ) : PlayerBarState()
}

/**
 * True when two states are the same except for [PlayerBarItem.elapsedTime] — the
 * `distinctUntilChanged` predicate behind [MainDataSource.playerBarState].
 *
 * While something is playing, a queue-time event lands about once a second and re-emits this
 * whole projection. Almost always the *only* difference is `elapsedTime`, and every downstream
 * consumer pays for it: Swift rebuilds a `PlayerBarItemView` per player and a
 * `QueueBarItemView` per queue item — each with a `URL(string:)` parse — and SwiftUI invalidates
 * the mini player, the expanded player and the queue list. With a few hundred queue items that
 * is thousands of allocations and URL parses a second, with the queue UI closed.
 *
 * Dropping those emissions is safe because `elapsedTime` is documented as a snapshot and is very
 * nearly vestigial: the only Swift reader is `livePosition ?? player.elapsedTime ?? 0`, and
 * `livePosition` comes from `PlayerPositionTracker.observe`, which is a `StateFlow` behind
 * `flatMapLatest` and therefore emits immediately on subscribe. The fallback covers at most one
 * frame.
 *
 * Note what this deliberately does *not* do: remove `elapsedTime` from the model. That is the
 * obvious version of this fix and it's the one that can show a seek bar at 0:00. Keeping the
 * field means a suppressed run leaves a stale value that nothing reads, rather than no value at
 * all — and any real change re-emits it fresh alongside whatever else moved.
 */
internal fun playerBarStatesEquivalentIgnoringElapsed(
    old: PlayerBarState,
    new: PlayerBarState,
): Boolean {
    if (old !is PlayerBarState.Data || new !is PlayerBarState.Data) return old == new
    if (old.selectedIndex != new.selectedIndex) return false
    // Explicit, unlike the players below: a chapter boundary changes nothing else on the
    // projection, so folding it into the elapsed-ignoring comparison would swallow the one
    // emission that flips the scrubber to the next chapter.
    if (old.presentationChapter != new.presentationChapter) return false
    if (old.players.size != new.players.size) return false
    // Copying the new elapsed onto the old item reduces "equal except elapsedTime" to a plain
    // data-class comparison, so this can't drift out of sync as fields are added to
    // PlayerBarItem — which a hand-written field-by-field check certainly would.
    return old.players.indices.all { index ->
        val oldItem = old.players[index]
        val newItem = new.players[index]
        oldItem.copy(elapsedTime = newItem.elapsedTime) == newItem
    }
}

/**
 * Derives [PlayerBarState] from [MainDataSource.playersData]/[MainDataSource.selectedPlayerIndex] —
 * mirrors the same `DataState.Data`-only gating [MainDataSource.selectedPlayerIndex]/
 * [MainDataSource.isAnythingPlaying] already use: Loading/Error/NoData/Stale all collapse to
 * [PlayerBarState.Loading]. Stale isn't special-cased into "show last known data" here since
 * [MainDataSource.selectedPlayerIndex] itself doesn't survive Stale either — mirroring that
 * existing gap rather than inventing behavior neither of them has today.
 */
/**
 * Per-player memo for the queue projection, keyed on the *identity* of the source list.
 *
 * [MainDataSource.buildPlayerDataList] carries loaded queue items across rebuilds by reference
 * (`updateFrom` keeps `oldQueueData.items` when the incoming state has none), so on a queue-time
 * tick the source list is literally the same object as last time. Mapping it again produced a
 * fresh `QueueBarItem` per track — plus an `image(THUMB)` lookup each — several hundred times a
 * second, only for the result to be discarded by the `distinctUntilChanged` in
 * [MainDataSource.playerBarState].
 *
 * Returning the previous list instance has a second effect worth as much as the first: the
 * data-class equality behind that `distinctUntilChanged` then short-circuits on identity
 * (`AbstractList.equals` checks `this === other` first) instead of walking a few hundred items
 * field by field.
 *
 * Identity, not equality, on purpose — an equality check here would cost the very comparison it
 * is meant to avoid. A miss is only ever a missed optimization: the items are re-projected and
 * the result is correct either way.
 *
 * Not thread-safe, and doesn't need to be: the only caller is a single flow collector, which
 * processes emissions sequentially with a happens-before between them.
 */
internal class QueueProjectionCache {
    private class Entry(val source: List<QueueTrack>, val projected: List<QueueBarItem>)

    private val entries = mutableMapOf<String, Entry>()

    fun project(playerId: String, source: List<QueueTrack>?): List<QueueBarItem> {
        if (source.isNullOrEmpty()) {
            entries.remove(playerId)
            return emptyList()
        }
        entries[playerId]?.let { cached ->
            if (cached.source === source) return cached.projected
        }
        val projected = source.map { queueTrack ->
            val itemMedia = queueTrack.track as? AppMediaItem
            QueueBarItem(
                id = queueTrack.id,
                title = itemMedia?.displayName ?: itemMedia?.name.orEmpty(),
                subtitle = itemMedia?.subtitle,
                artworkUrl = itemMedia?.image(ImageType.THUMB)?.url,
                isPlayable = queueTrack.isPlayable,
                trackItem = itemMedia,
            )
        }
        entries[playerId] = Entry(source, projected)
        return projected
    }

    /** Drops players that no longer exist, so a long session can't accumulate their queues. */
    fun retainOnly(playerIds: Set<String>) {
        if (entries.isNotEmpty()) entries.keys.retainAll(playerIds)
    }
}

internal fun buildPlayerBarState(
    playersDataState: DataState<List<PlayerData>>,
    selectedIndex: Int?,
    // Defaults to a throwaway cache so the function stays pure for callers that don't have one —
    // notably the tests, which would otherwise all have to thread an instance through.
    queueCache: QueueProjectionCache = QueueProjectionCache(),
    presentationChapter: ChapterBarItem? = null,
): PlayerBarState {
    val players = (playersDataState as? DataState.Data)?.data ?: return PlayerBarState.Loading
    if (players.isEmpty()) return PlayerBarState.Empty
    queueCache.retainOnly(players.mapTo(mutableSetOf()) { it.playerId })
    return PlayerBarState.Data(
        players = players.map { data ->
            val player = data.player
            val queue = data.queueInfo
            PlayerBarItem(
                playerId = data.playerId,
                name = player.nameAndSuffix,
                icon = player.icon,
                isPlaying = player.isPlaying,
                isPoweredOff = player.isPoweredOff,
                title = player.currentMedia?.title,
                subtitle = player.currentMedia?.subtitle,
                artworkUrl = player.currentMedia?.imageUrl,
                canPlay = player.canPlay && !player.isAnnouncing,
                duration = player.currentMedia?.duration,
                elapsedTime = queue?.elapsedTime,
                shuffleEnabled = queue?.shuffleEnabled ?: false,
                repeatMode = queue?.repeatMode,
                isDynamicPlaylist = queue?.isDynamicPlaylist ?: false,
                volumeLevel = player.currentVolume.takeIf { player.isVolumeSliderAccessible },
                isMuted = player.currentMuteState,
                canMute = player.canMute,
                sleepTimerExpiresAt = player.sleepTimerExpiresAt,
                trackItem = queue?.currentItem?.track as? AppMediaItem,
                queueId = data.queueOrPlayerId,
                queueItems = queueCache.project(data.playerId, data.queueItems),
                currentQueueItemId = queue?.currentItem?.id,
                currentItemChapters = (queue?.currentItem?.track as? Audiobook)?.chapters.orEmpty(),
                isSpokenWord = queue?.currentItem?.track
                    .let { it is Audiobook || it is PodcastEpisode },
                isGroup = player.isGroup,
                isGrouped = player.isGrouped,
                groupVolume = player.groupVolume,
                groupVolumeMuted = player.groupVolumeMuted,
                ownVolume = player.volumeLevel,
                ownVolumeMuted = player.volumeMuted,
                volumeSliderAccessible = player.isVolumeSliderAccessible,
                groupMembers = data.childrenBinds
                    .sortedByDescending { it.isBound }
                    .map { bind ->
                        GroupMemberBarItem(
                            id = bind.id,
                            name = bind.name,
                            volume = bind.volume,
                            volumeSliderAccessible = bind.volumeSliderAccessible,
                            isMuted = bind.isMuted ?: false,
                            canMute = bind.isMuted != null,
                            isBound = bind.isBound,
                            isManageable = bind.isManageable,
                        )
                    },
            )
        },
        selectedIndex = selectedIndex?.takeIf { it in players.indices } ?: 0,
        presentationChapter = presentationChapter,
    )
}
