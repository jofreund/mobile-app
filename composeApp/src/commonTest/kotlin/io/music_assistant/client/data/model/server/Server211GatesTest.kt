package io.music_assistant.client.data.model.server

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Every server 2.11 behaviour gates on [SERVER_2_11_SCHEMA]; an unknown schema keeps 2.10's. */
class Server211GatesTest {
    @Test
    fun theGatesOpenAtTheTwoElevenSchema() {
        for (gate in listOf(::pagesPlaylistTracksAndEpisodes, ::sendsFavoriteUpdates, ::supportsAppSignIn)) {
            assertFalse(gate(null), "unknown schema")
            assertFalse(gate(SERVER_2_11_SCHEMA - 1), "2.10")
            assertTrue(gate(SERVER_2_11_SCHEMA), "2.11")
        }
    }
}
