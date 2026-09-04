package io.music_assistant.client.data.model.client

import io.music_assistant.client.data.model.client.AppMediaItemFixtures.track
import io.music_assistant.client.data.model.client.PlayerDataFixtures.toPlayerMedia
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * A player fed by another source (a HomePod on Apple Music, a Home Assistant media player
 * driven by some other app) has an idle MA queue whose elapsed time is stale. The only
 * position that means anything is the player's own, and only for such a player: for MA
 * playback the queue is the position and the player's field is stream-relative.
 */
class ExternalMediaPositionTest {
    private val externalMedia = PlayerMedia(
        title = "The Sum",
        artist = "Lambert & Dekker",
        album = "I Am Not Lambert",
        imageUrl = null,
        duration = 201.0,
        queueId = null,
        queueItemId = null,
        mediaType = MediaType.TRACK,
        uri = "apple-music://song",
    )

    private fun external(
        isPlaying: Boolean = true,
        elapsedTime: Double? = 60.0,
        lastUpdated: Double? = 1_000.0,
        media: PlayerMedia? = externalMedia,
    ) = PlayerDataFixtures.player(currentMedia = media).copy(
        isPlaying = isPlaying,
        elapsedTime = elapsedTime,
        elapsedTimeLastUpdated = lastUpdated,
    )

    @Test
    fun `media without a queue stamp is external and stamped media is not`() {
        assertTrue(external().hasExternalMedia)
        assertFalse(external(media = track().toPlayerMedia()).hasExternalMedia)
        assertFalse(external(media = null).hasExternalMedia)
    }

    @Test
    fun `a playing player advances by the wall time since the report`() {
        assertEquals(75.0, external().externalElapsedSec(nowEpochSec = 1_015.0))
    }

    @Test
    fun `a paused player sits where it was reported`() {
        assertEquals(60.0, external(isPlaying = false).externalElapsedSec(nowEpochSec = 1_015.0))
    }

    @Test
    fun `the projection never runs past the media duration`() {
        assertEquals(201.0, external().externalElapsedSec(nowEpochSec = 9_999.0))
    }

    @Test
    fun `a report from the future is not subtracted`() {
        // Clock skew between the phone and the server must not pull the position backwards.
        assertEquals(60.0, external().externalElapsedSec(nowEpochSec = 990.0))
    }

    @Test
    fun `without a report timestamp the position is used as is`() {
        assertEquals(60.0, external(lastUpdated = null).externalElapsedSec(nowEpochSec = 1_015.0))
    }

    @Test
    fun `MA playback and unreported positions yield nothing`() {
        assertNull(external(media = track().toPlayerMedia()).externalElapsedSec(1_015.0))
        assertNull(external(elapsedTime = null).externalElapsedSec(1_015.0))
    }
}
