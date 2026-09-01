package io.music_assistant.client.data.model.client

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins [io.music_assistant.client.data.model.client.items.AppMediaItem.referenceUri] — the
 * `provider://media_type/item_id` reference the server resolves items by.
 *
 * The podcast case is the one that broke favoriting: the server's RSS parser puts the feed's
 * `<link>` (the show's website) in a provider podcast's `uri`, and sending that to
 * `music/favorites/add_item` had the server ffprobe a web page and answer `invalid_data`.
 */
class ReferenceUriTest {
    private val feedUrl = "https://geschichten-aus-der-geschichte.podigee.io/feed/mp3"

    @Test
    fun podcastWithAWebsiteUriIsAddressedByItsProviderAndItemId() {
        val podcast = testPodcast().copy(
            itemId = feedUrl,
            provider = "itunes_podcasts--abc",
            uri = "https://www.geschichte.fm/",
        )

        assertEquals("itunes_podcasts--abc://podcast/$feedUrl", podcast.referenceUri)
        assertEquals(podcast.referenceUri, podcast.mediaUri)
    }

    @Test
    fun aServerUriThatAddressesTheItemsProviderIsUsedAsIs() {
        val podcast = testPodcast().copy(
            itemId = "17",
            provider = "library",
            uri = "library://podcast/17",
        )

        assertEquals("library://podcast/17", podcast.referenceUri)
    }

    @Test
    fun aMissingUriIsSynthesized() {
        // Genres arrive without one — this is what `Genre.mediaUri` used to hand-build.
        assertEquals("test://genre/id", testGenre().referenceUri)
        assertEquals("test://track/id", testTrack().referenceUri)
    }
}
