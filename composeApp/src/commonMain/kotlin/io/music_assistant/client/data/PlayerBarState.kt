package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.RepeatMode
import io.music_assistant.client.data.model.client.items.AppMediaItem
import io.music_assistant.client.ui.compose.common.DataState

/**
 * Flat, Swift-bridgeable projection of [PlayerData] for the native mini and expanded player —
 * mirrors the "flatten at the bridge boundary" pattern `SpikeMediaItem` uses over
 * `AppMediaItem`, rather than exporting `Player`/`PlayerData`/`PlayerMedia` directly. One shape
 * for both: the mini player only reads the first eight fields, the expanded player also reads
 * the rest (duration/elapsedTime/shuffle/repeat/volume/trackItem) — mirrors Compose's own
 * `PlayersPager`, which shares one `HorizontalPager`/state for both collapsed and expanded.
 */
data class PlayerBarItem(
    val playerId: String,
    val name: String,
    val isLocal: Boolean,
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
    /** The current queue track, exposed so Swift can reuse the existing `setFavorite`/`favorite`/`uri`
     * fields directly instead of adding separate favorite-specific fields here. */
    val trackItem: AppMediaItem?,
)

sealed class PlayerBarState {
    data object Loading : PlayerBarState()
    data object Empty : PlayerBarState()
    data class Data(val players: List<PlayerBarItem>, val selectedIndex: Int) : PlayerBarState()
}

/**
 * Derives [PlayerBarState] from [MainDataSource.playersData]/[MainDataSource.selectedPlayerIndex] —
 * mirrors the same `DataState.Data`-only gating [MainDataSource.selectedPlayerIndex]/
 * [MainDataSource.isAnythingPlaying] already use: Loading/Error/NoData/Stale all collapse to
 * [PlayerBarState.Loading]. Stale isn't special-cased into "show last known data" here since
 * [MainDataSource.selectedPlayerIndex] itself doesn't survive Stale either — mirroring that
 * existing gap rather than inventing behavior neither of them has today.
 */
internal fun buildPlayerBarState(
    playersDataState: DataState<List<PlayerData>>,
    selectedIndex: Int?,
): PlayerBarState {
    val players = (playersDataState as? DataState.Data)?.data ?: return PlayerBarState.Loading
    if (players.isEmpty()) return PlayerBarState.Empty
    return PlayerBarState.Data(
        players = players.map { data ->
            val player = data.player
            val queue = data.queueInfo
            PlayerBarItem(
                playerId = data.playerId,
                name = player.nameAndSuffix,
                isLocal = data.isLocal,
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
                trackItem = queue?.currentItem?.track as? AppMediaItem,
            )
        },
        selectedIndex = selectedIndex?.takeIf { it in players.indices } ?: 0,
    )
}
