package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.ui.compose.common.DataState

/**
 * Flat, Swift-bridgeable projection of [PlayerData] for the native mini player — mirrors the
 * "flatten at the bridge boundary" pattern `SpikeMediaItem` uses over `AppMediaItem`, rather
 * than exporting `Player`/`PlayerData`/`PlayerMedia` directly.
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
            PlayerBarItem(
                playerId = data.playerId,
                name = data.player.nameAndSuffix,
                isLocal = data.isLocal,
                isPlaying = data.player.isPlaying,
                isPoweredOff = data.player.isPoweredOff,
                title = data.player.currentMedia?.title,
                subtitle = data.player.currentMedia?.subtitle,
                artworkUrl = data.player.currentMedia?.imageUrl,
            )
        },
        selectedIndex = selectedIndex?.takeIf { it in players.indices } ?: 0,
    )
}
