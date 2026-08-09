package io.music_assistant.client.data.model.client

/**
 * Mirrors the server's `AlbumType`, used as the `album_types` library filter for
 * albums. `UNKNOWN` is intentionally omitted (not a useful filter); [serverValue]s
 * match `music_assistant_models`.
 */
enum class AlbumType(val serverValue: String) {
    ALBUM("album"),
    SINGLE("single"),
    LIVE("live"),
    SOUNDTRACK("soundtrack"),
    COMPILATION("compilation"),
    EP("ep"),
    ;

    companion object {
        private val byServerValue = entries.associateBy { it.serverValue }
        fun fromServer(raw: String?): AlbumType? = raw?.let { byServerValue[it] }
    }
}
