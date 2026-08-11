package io.music_assistant.client.data

import io.music_assistant.client.data.MainDataSource.Companion.preserveThroughResync
import io.music_assistant.client.data.model.client.Player
import io.music_assistant.client.data.model.client.PlayerDataFixtures.player
import io.music_assistant.client.ui.compose.common.DataState
import io.music_assistant.client.ui.compose.common.StaleReason
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Unit tests for [MainDataSource.preserveThroughResync] — what the player list shows while a
 * freshly-authenticated connection re-fetches everything from the server.
 *
 * The re-fetch itself is unconditional at the call site (a reconnect always follows a gap in
 * the event stream, and nothing replays what was missed), so the only decision left is whether
 * the user watches a populated list refresh in place or watches it vanish and come back.
 */
class ResyncPreservationTest {
    private val players = listOf(player(name = "Kitchen"), player(name = "Office"))

    @Test
    fun `stale data from a reconnect stays on screen`() {
        // The app-backgrounding case: the socket went away and came back. Whatever the list
        // holds is very probably still nearly right, so it is promoted straight back to Data
        // and the fetch corrects it in place — no blink through "Loading players".
        val result = preserveThroughResync(
            DataState.Stale(
                data = players,
                disconnectedAt = 1_000L,
                reason = StaleReason.RECONNECTING,
            ),
        )

        assertEquals(DataState.Data(players), result)
    }

    @Test
    fun `stale data from a persistent error stays on screen too`() {
        // Longer outage, same answer. The reason a connection dropped says nothing about how
        // much the data has drifted, so it doesn't get a say in what's displayed either.
        val result = preserveThroughResync(
            DataState.Stale(
                data = players,
                disconnectedAt = 1_000L,
                reason = StaleReason.PERSISTENT_ERROR,
            ),
        )

        assertEquals(DataState.Data(players), result)
    }

    @Test
    fun `already-fresh data is passed through unchanged`() {
        // Identity, not equality: returning an equal-but-new Data would push a pointless
        // emission through every downstream collector, all the way out to SwiftUI.
        val current = DataState.Data(players)

        assertSame(current, preserveThroughResync(current))
    }

    @Test
    fun `nothing to preserve falls back to loading`() {
        // Cold start, or data cleared by a logout. There is no last-known-good list to hold
        // on to, so Loading is the honest thing to show until the fetch lands.
        val empty = listOf<DataState<List<Player>>>(
            DataState.Loading(),
            DataState.NoData(),
            DataState.Error(),
        )

        empty.forEach { state ->
            assertTrue(
                preserveThroughResync(state) is DataState.Loading,
                "${state::class.simpleName} has nothing worth preserving",
            )
        }
    }
}
