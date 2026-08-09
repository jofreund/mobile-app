package io.music_assistant.client.ui.compose.library

import io.music_assistant.client.data.model.client.MediaType

enum class LibraryCategory {
    ARTISTS, ALBUMS, TRACKS, PLAYLISTS, AUDIOBOOKS, PODCASTS, RADIOS, GENRES, BROWSE;

    /** Path-based [BROWSE] is not a media type, hence nullable. */
    val mediaType: MediaType?
        get() = when (this) {
            ARTISTS -> MediaType.ARTIST
            ALBUMS -> MediaType.ALBUM
            TRACKS -> MediaType.TRACK
            PLAYLISTS -> MediaType.PLAYLIST
            AUDIOBOOKS -> MediaType.AUDIOBOOK
            PODCASTS -> MediaType.PODCAST
            RADIOS -> MediaType.RADIO
            GENRES -> MediaType.GENRE
            BROWSE -> null
        }
}

/** Tabs Android Auto / CarPlay can render at root — Tracks/Genres aren't AA tabs. */
val carTabCategories: List<LibraryCategory> = listOf(
    LibraryCategory.ARTISTS,
    LibraryCategory.ALBUMS,
    LibraryCategory.PLAYLISTS,
    LibraryCategory.PODCASTS,
    LibraryCategory.RADIOS,
    LibraryCategory.AUDIOBOOKS,
)
