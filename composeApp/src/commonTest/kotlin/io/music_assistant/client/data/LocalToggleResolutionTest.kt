package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.PlayerDataFixtures
import io.music_assistant.client.ui.compose.common.action.PlayerAction
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * A local play/pause toggle must resolve to the explicit action before it can reach the
 * offline queue: a queued `play_pause` would replay against the server's state, not the
 * one the user saw when they tapped.
 */
class LocalToggleResolutionTest {
    @Test
    fun aLocalToggleResolvesAgainstTheStateTheUserSees() {
        assertEquals(
            PlayerAction.Play,
            resolveLocalToggle(playerData(isPlaying = false), PlayerAction.TogglePlayPause),
        )
        assertEquals(
            PlayerAction.Pause,
            resolveLocalToggle(playerData(isPlaying = true), PlayerAction.TogglePlayPause),
        )
    }

    @Test
    fun aPendingPlayCountsAsPlayingSoTheNextToggleCancelsIt() {
        assertEquals(
            PlayerAction.Pause,
            resolveLocalToggle(
                playerData(isPlaying = false, pendingPlay = true),
                PlayerAction.TogglePlayPause,
            ),
        )
    }

    @Test
    fun everyOtherActionPassesThrough() {
        val data = playerData(isPlaying = true)
        assertEquals(PlayerAction.Next, resolveLocalToggle(data, PlayerAction.Next))
        assertEquals(PlayerAction.Play, resolveLocalToggle(data, PlayerAction.Play))
        assertEquals(PlayerAction.SeekTo(42), resolveLocalToggle(data, PlayerAction.SeekTo(42)))
    }

    private fun playerData(isPlaying: Boolean, pendingPlay: Boolean = false): PlayerData {
        val base = PlayerDataFixtures.playerData()
        return base.copy(player = base.player.copy(isPlaying = isPlaying), pendingPlay = pendingPlay)
    }
}
