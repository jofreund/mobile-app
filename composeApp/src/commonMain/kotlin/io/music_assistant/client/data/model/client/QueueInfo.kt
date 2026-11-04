package io.music_assistant.client.data.model.client

import io.music_assistant.client.data.model.client.items.AppMediaItem

data class QueueInfo(
    val id: String,
    val available: Boolean,
    val currentIndex: Int?,
    val shuffleEnabled: Boolean,
    val repeatMode: RepeatMode?,
    val autoPlayEnabled: Boolean?,
    /**
     * True when the server reported the setting under its current name (`autoplay_enabled`) and
     * therefore understands `player_queues/autoplay`; false selects the deprecated
     * `player_queues/dont_stop_the_music` alias. A payload-shaped feature gate rather than a
     * schema constant — the server answers the question itself, per queue.
     */
    val supportsAutoplayCommand: Boolean = false,
    /** Null when the server sends no `crossfade_enabled` at all: no crossfade control to show. */
    val crossfadeEnabled: Boolean? = null,
    val elapsedTime: Double?,
    /**
     * Unix epoch seconds (UTC) when [elapsedTime] was last recomputed
     * server-side. Drives [isBefore]. Optimistic writes bump this above
     * the last known server stamp; see `LocalPlayerAdapter`.
     */
    val elapsedTimeLastUpdated: Double?,
    val currentItem: QueueTrack?,
    val radioSource: List<AppMediaItem>,
    /** Server-derived: the active source is a dynamic/smart playlist (rule-generated). */
    val isDynamicPlaylist: Boolean = false,
    val playbackSpeed: Double? = null,
    /** Number of items in the queue, or null when the server did not send it. */
    val itemCount: Int? = null,
) {
    val isRadioOn: Boolean = radioSource.isNotEmpty()
}

/**
 * Whether a plain `next` moves the queue. The server ignores it without a current item, and on
 * the last item unless repeat is ALL (`player_queues/next`). An unknown count counts as a move.
 */
val QueueInfo.nextMovesQueue: Boolean
    get() {
        val index = currentIndex ?: return false
        val count = itemCount ?: return true
        return index < count - 1 || repeatMode == RepeatMode.ALL
    }

/** Strict-older-than on [QueueInfo.elapsedTimeLastUpdated]. Callers match ids first. */
fun QueueInfo.isBefore(other: QueueInfo): Boolean {
    val mine = elapsedTimeLastUpdated ?: return false
    val theirs = other.elapsedTimeLastUpdated ?: return false
    return mine < theirs
}
