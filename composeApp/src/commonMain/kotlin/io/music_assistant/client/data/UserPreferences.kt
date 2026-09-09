package io.music_assistant.client.data

import io.music_assistant.client.data.model.server.ServerUser
import io.music_assistant.client.data.model.server.ServerUserPreferences
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * Server-synced state about the signed-in user from `auth/me` — their preferences, and
 * who they are — shared by every surface.
 *
 * This client has no settings UI for the preferences: the web frontend owns the toggles and
 * this client refreshes them on each authenticated connect. An absent field keeps the
 * documented server default, so a server that has never written the preference behaves
 * the same as one that wrote the default explicitly.
 */
class UserPreferences {
    private val _preferences = MutableStateFlow(ServerUserPreferences())
    private val _signedInUserId = MutableStateFlow<String?>(null)

    /** Reactive view of the whole preference set. */
    val preferences: StateFlow<ServerUserPreferences> = _preferences

    /** Chapter-based progress and navigation; the server default is on. */
    val chapterProgressEnabled: Flow<Boolean> =
        _preferences.map { it.chapterProgressEnabled }.distinctUntilChanged()

    /** Synchronous read for command-path call sites. */
    val isChapterProgressEnabled: Boolean get() = _preferences.value.chapterProgressEnabled

    /**
     * Who the app is signed in as on this server, or null when the server did not say.
     *
     * Server-side records kept per user name their user; this is what an event about one
     * of them is matched against, so another user's playback does not move what this one
     * is shown (see `MainDataSource.followResumePoint`).
     */
    val signedInUserId: String? get() = _signedInUserId.value

    /** Caches a fetched `auth/me`; a failed fetch keeps the current values. */
    fun update(user: ServerUser) {
        _signedInUserId.value = user.userId ?: _signedInUserId.value
        update(user.preferences)
    }

    /** Caches a fetched set; a failed fetch keeps the current values. */
    fun update(preferences: ServerUserPreferences?) {
        preferences?.let { _preferences.value = it }
    }

    /** Drops cached values so the next server does not inherit them. */
    fun clear() {
        _preferences.value = ServerUserPreferences()
        _signedInUserId.value = null
    }
}
