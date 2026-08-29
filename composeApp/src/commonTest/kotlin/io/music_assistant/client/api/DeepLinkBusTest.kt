package io.music_assistant.client.api

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The `/players` route's parsing contract, exercised for both link forms. The optional
 * player-id segment is what the Live Activity's tap URL rides on — a regression here
 * degrades an activity tap from "open this player" back to "open whatever is selected".
 */
class DeepLinkBusTest {
    private fun parse(url: String): DeepLinkDestination? =
        DeepLinkBus().apply { handle(url) }.pending.value

    @Test
    fun `players without an id carries no player`() {
        assertEquals(
            DeepLinkDestination.Players(playerId = null),
            parse("musicassistant://app/players"),
        )
    }

    @Test
    fun `players with an id carries the id`() {
        assertEquals(
            DeepLinkDestination.Players(playerId = "ap12345678"),
            parse("musicassistant://app/players/ap12345678"),
        )
    }

    @Test
    fun `a percent-encoded id is decoded`() {
        // Player ids are server-issued opaque strings; the widget percent-encodes them
        // into the path, so spaces (and any reserved characters) must round-trip.
        assertEquals(
            DeepLinkDestination.Players(playerId = "media_player.living room"),
            parse("musicassistant://app/players/media_player.living%20room"),
        )
    }

    @Test
    fun `the universal link form carries the id too`() {
        assertEquals(
            DeepLinkDestination.Players(playerId = "ap12345678"),
            parse("https://app.music-assistant.io/app/players/ap12345678"),
        )
    }

    @Test
    fun `consume clears the matching destination`() {
        val bus = DeepLinkBus()
        bus.handle("musicassistant://app/players/ap12345678")
        bus.consume(DeepLinkDestination.Players(playerId = "ap12345678"))
        assertNull(bus.pending.value)
    }

    @Test
    fun `consume of a stale destination leaves a newer one pending`() {
        val bus = DeepLinkBus()
        bus.handle("musicassistant://app/players/first")
        bus.handle("musicassistant://app/players/second")
        bus.consume(DeepLinkDestination.Players(playerId = "first"))
        assertEquals(DeepLinkDestination.Players(playerId = "second"), bus.pending.value)
    }
}
