package io.music_assistant.client.data.model.client

data class PlayerMedia(
    val title: String?,
    val artist: String?,
    val album: String?,
    val imageUrl: String?,
    val duration: Double?,
    val queueId: String?,
    val queueItemId: String?,
    val mediaType: MediaType?,
    val uri: String?,
) {
    val subtitle = listOfNotNull(artist, album)
        .takeIf { it.isNotEmpty() }?.joinToString(" • ")
}
