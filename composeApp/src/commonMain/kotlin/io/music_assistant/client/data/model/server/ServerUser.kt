package io.music_assistant.client.data.model.server

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class ServerUser(
    /**
     * The signed-in user's id, as `auth/me` reports it. Server-side records that are kept
     * per user — the playlog, and so the resume point of an audiobook or episode — name the
     * user they belong to with this id.
     */
    @SerialName("user_id") val userId: String? = null,
    @SerialName("preferences") val preferences: ServerUserPreferences? = null,
)

@Serializable
data class ServerUserPreferences(
    @SerialName("sidebar.shortcuts") val shortcuts: List<String>? = null,
    // Chapter-based progress/navigation for audiobooks & podcasts; the web
    // frontend owns the settings toggle. Absent means the default (true).
    @SerialName("audiobook_chapter_progress") val audiobookChapterProgress: Boolean? = null,
) {
    /** Resolved chapter gate; an absent field means the server default. */
    val chapterProgressEnabled: Boolean get() = audiobookChapterProgress != false
}
