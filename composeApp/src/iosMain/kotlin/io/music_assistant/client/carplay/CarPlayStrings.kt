package io.music_assistant.client.carplay

import io.music_assistant.client.settings.DefaultClickOption
import io.music_assistant.client.utils.localizedString

/**
 * CarPlay UI strings resolved once for the active locale from the app's `.xcstrings` catalog —
 * the same Lokalise-managed source the rest of the app uses. This keeps CarPlay in lockstep with
 * app translations instead of shipping a separate iOS string store. Swift reads the fields
 * synchronously after [load] completes (template titles are immutable once constructed, so they
 * must be known before the first template is built).
 *
 * Reads through [localizedString] rather than compose-resources' `getString`, which is what used
 * to hold the Compose dependency in place for this file. Same catalog either way — the keys moved
 * to `Localizable.xcstrings` in Phase D. [load] no longer needs to suspend as a result, but keeps
 * its `suspend` signature so the bridge and its Swift caller keep their existing callback timing.
 */
class CarPlayStrings internal constructor(
    val library: String,
    val browse: String,
    val browseSubtitle: String,
    val loading: String,
    val empty: String,
    val playAll: String,
    val addAllToQueue: String,
    val ok: String,
    val offlineAlert: String,
    val disconnected: String,
    val artists: String,
    val albums: String,
    val tracks: String,
    val playlists: String,
    val audiobooks: String,
    val podcasts: String,
    val radio: String,
    private val albumsByArtistTemplate: String,
    private val bulkActionTitlesByName: Map<String, String>,
) {
    /**
     * Localized "Albums by <artist>" drilldown title. The placeholder is `%1$@`, Foundation's
     * spelling — the compose-resources catalog this used to read wrote the same slot as `%1$s`.
     */
    fun albumsByArtist(name: String): String =
        albumsByArtistTemplate.replace("%1\$@", name)

    /** Localized title for a bulk-action name (DefaultClickAction.name); falls back to "Play all". */
    fun bulkActionTitle(name: String): String = bulkActionTitlesByName[name] ?: playAll

    companion object {
        @Suppress("RedundantSuspendModifier") // see the class doc — kept for the bridge's timing
        suspend fun load(): CarPlayStrings = CarPlayStrings(
            library = localizedString("nav_library"),
            browse = localizedString("action_browse"),
            browseSubtitle = localizedString("browse_subtitle"),
            loading = localizedString("loading"),
            empty = localizedString("library_empty"),
            playAll = localizedString("action_play_all"),
            addAllToQueue = localizedString("action_add_all_to_queue"),
            ok = localizedString("action_ok"),
            offlineAlert = localizedString("not_connected_retry"),
            disconnected = localizedString("connection_lost"),
            artists = localizedString("media_type_artists"),
            albums = localizedString("media_type_albums"),
            tracks = localizedString("media_type_tracks"),
            playlists = localizedString("media_type_playlists"),
            audiobooks = localizedString("media_type_audiobooks"),
            podcasts = localizedString("media_type_podcasts"),
            radio = localizedString("media_type_radio"),
            albumsByArtistTemplate = localizedString("albums_by_artist"),
            bulkActionTitlesByName = mapOf(
                DefaultClickOption.PLAY_NOW.name to localizedString("action_play_all"),
                DefaultClickOption.INSERT_NEXT_AND_PLAY.name to localizedString("action_insert_next_and_play"),
                DefaultClickOption.INSERT_NEXT.name to localizedString("action_insert_next"),
                DefaultClickOption.ADD_TO_QUEUE.name to localizedString("action_add_all_to_queue"),
                DefaultClickOption.START_RADIO.name to localizedString("action_start_radio"),
            ),
        )
    }
}
