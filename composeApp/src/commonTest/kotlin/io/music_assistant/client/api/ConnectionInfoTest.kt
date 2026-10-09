package io.music_assistant.client.api

import kotlin.test.Test
import kotlin.test.assertEquals

class ConnectionInfoTest {
    @Test
    fun `live announcement socket sits on the webserver next to the api`() {
        assertEquals(
            "ws://nas.local:8095/live_announcement",
            ConnectionInfo(host = "nas.local", port = 8095, isTls = false).liveAnnouncementUrl,
        )
        assertEquals(
            "wss://ma.example.org:8443/live_announcement",
            ConnectionInfo(host = "ma.example.org", port = 8443, isTls = true).liveAnnouncementUrl,
        )
    }
}
