package io.music_assistant.client.data.model.client.items

import io.music_assistant.client.data.model.client.ImageInfo
import io.music_assistant.client.data.model.client.ImageType
import io.music_assistant.client.data.model.client.MediaType
import io.music_assistant.client.data.model.client.Metadata
import io.music_assistant.client.data.model.server.ProviderMapping

data class RadioStation(
    override val itemId: String,
    override val provider: String,
    override val name: String,
    override val providerMappings: List<ProviderMapping>?,
    override val metadata: Metadata?,
    override val favorite: Boolean?,
    override val sortName: String? = null,
    override val uri: String?,
    override val images: Map<ImageType, ImageInfo>,
    override val version: String?,
    override val isPlayable: Boolean,
    /** Server-derived: a dynamic station whose stream is generated per listener (2.10+). */
    val isDynamic: Boolean,
) : AppMediaItem(), PlayableItem {
    override val mediaType: MediaType = MediaType.RADIO
    override val duration: Double? = null
    override val parentName: String? = null
    override fun withFavorite(favorite: Boolean?) = copy(favorite = favorite)
}
