package io.music_assistant.client.data.model.client

import io.music_assistant.client.data.model.server.ProviderMapping
import io.music_assistant.client.data.model.server.ServerMediaItem
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Library membership from the `in_library` flag of the provider mappings (upstream #1382). */
class LibraryMembershipTest {
    private fun mapping(inLibrary: Boolean?) = ProviderMapping("s1", "spotify", "spotify-1", inLibrary = inLibrary)

    private fun libraryAlbum(inLibrary: Boolean?, favorite: Boolean? = null) = testAlbum().copy(
        provider = ServerMediaItem.LIBRARY_PROVIDER,
        providerMappings = listOf(mapping(inLibrary)),
        favorite = favorite,
    )

    @Test
    fun aLibraryRowWithAMappingInTheLibraryIsInTheLibrary() {
        assertTrue(libraryAlbum(inLibrary = true).isInLibrary)
    }

    @Test
    fun aLibraryRowKeptForALibraryTrackIsNotInTheLibrary() {
        val album = libraryAlbum(inLibrary = false)
        assertTrue(album.isLibraryItem)
        assertFalse(album.isInLibrary)
    }

    @Test
    fun aLikedLibraryRowIsInTheLibrary() {
        assertTrue(libraryAlbum(inLibrary = false, favorite = true).isInLibrary)
    }

    @Test
    fun aLibraryRowIsInTheLibraryWhenTheServerSendsNoFlag() {
        assertTrue(libraryAlbum(inLibrary = null).isInLibrary)
    }

    @Test
    fun anItemOfAMusicServiceIsNotInTheLibrary() {
        val album = testAlbum().copy(providerMappings = listOf(mapping(inLibrary = true)))
        assertFalse(album.isLibraryItem)
        assertFalse(album.isInLibrary)
    }
}
