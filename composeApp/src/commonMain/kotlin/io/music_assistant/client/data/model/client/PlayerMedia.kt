package io.music_assistant.client.data.model.client

data class PlayerMedia(
    val title: String?,
    val artist: String?,
    val album: String?,
    val imageUrl: String?,
    val duration: Double?,
    /** Id of the source feeding this media — an MA queue's id, or another source's. */
    val sourceId: String?,
    /** Pre-rename queue id; current servers name the queue in [sourceId] instead. */
    val queueId: String?,
    val queueItemId: String?,
    val mediaType: MediaType?,
    val uri: String?,
) {
    val subtitle = listOfNotNull(artist, album)
        .takeIf { it.isNotEmpty() }?.joinToString(" • ")
}
