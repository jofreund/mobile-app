package io.music_assistant.client.api

import io.music_assistant.client.data.model.client.MediaType
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins the wire shape of the favorite commands against the server's api_command signatures.
 *
 * The two removal commands take deliberately different id arguments — `music/favorites/remove_item`
 * takes `item_id`, `music/library/remove_item` takes `library_item_id` — and getting them mixed up
 * is rejected server-side with `error_code` 3 (`invalid_data`), which is what broke un-favoriting.
 */
class FavoritesRequestTest {
    @Test
    fun addFavoriteCarriesTheItemUri() {
        val request = Request.Library.addFavorite("library://podcast/17")

        assertEquals("music/favorites/add_item", request.command)
        assertEquals(JsonPrimitive("library://podcast/17"), request.args?.get("item"))
        assertEquals(setOf("item"), request.args?.keys)
    }

    @Test
    fun removeFavoriteCarriesItemIdAndMediaType() {
        val request = Request.Library.removeFavorite("17", MediaType.PODCAST)

        assertEquals("music/favorites/remove_item", request.command)
        assertEquals(JsonPrimitive("17"), request.args?.get("item_id"))
        assertEquals(JsonPrimitive("podcast"), request.args?.get("media_type"))
        assertEquals(setOf("item_id", "media_type"), request.args?.keys)
    }

    @Test
    fun removeFromLibraryStillCarriesLibraryItemId() {
        val request = Request.Library.remove("17", MediaType.PODCAST)

        assertEquals("music/library/remove_item", request.command)
        assertEquals(JsonPrimitive("17"), request.args?.get("library_item_id"))
        assertEquals(JsonPrimitive("podcast"), request.args?.get("media_type"))
        assertEquals(setOf("library_item_id", "media_type"), request.args?.keys)
    }
}
