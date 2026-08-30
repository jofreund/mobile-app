package io.music_assistant.client.data.model.client.items

import io.music_assistant.client.data.model.client.ImageInfo
import io.music_assistant.client.data.model.client.ImageType
import io.music_assistant.client.data.model.client.MediaType
import io.music_assistant.client.data.model.client.Metadata
import io.music_assistant.client.data.model.client.QueueTrack
import io.music_assistant.client.data.model.server.AudioFormat
import io.music_assistant.client.data.model.server.ProviderMapping
import io.music_assistant.client.data.model.server.ServerMediaItem

interface PlayableItem {
    val parentName: String?
    val mediaType: MediaType
    val itemId: String
    val displayName: String
    val version: String?
    val duration: Double?
    val uri: String?
    val subtitle: String?
    val images: Map<ImageType, ImageInfo>
    val provider: String
    val isInLibrary: Boolean
    val favorite: Boolean?
    val longId: Long
        get() = itemId.hashCode().toLong()
    val canStartEndlessMix: Boolean

    val isPlayable: Boolean

    /** Returns a copy of this item with its [favorite] flag set to [favorite]. */
    fun withFavorite(favorite: Boolean?): PlayableItem
}

val PlayableItem?.isLongFormSpokenContent: Boolean
    get() = this is Audiobook || this is PodcastEpisode

object LongFormSeekDefaults {
    const val BACK_SECONDS = 10L
    const val FORWARD_SECONDS = 30L
}

/**
 * Items whose played/unplayed state can be marked on the server. Retains the original
 * [source] DTO so it can be echoed back verbatim — the server's `music/mark_played`
 * deserializes it into a full media item, which our decomposed client model can't
 * reconstruct (e.g. a podcast episode's required `position`/`podcast` fields).
 */
interface MarkableItem {
    val source: ServerMediaItem

    /**
     * A copy reflecting a new played state, for optimistically patching lists after a
     * mark request — the server only writes the playlog and emits no update event.
     */
    fun withPlayed(fullyPlayed: Boolean): AppMediaItem
}

sealed class AppMediaItem {
    abstract val itemId: String
    abstract val provider: String
    abstract val name: String
    abstract val providerMappings: List<ProviderMapping>?
    abstract val metadata: Metadata?
    abstract val favorite: Boolean?
    abstract val mediaType: MediaType
    abstract val sortName: String?
    abstract val uri: String?
    abstract val images: Map<ImageType, ImageInfo>
    open val canStartEndlessMix: Boolean get() = false

    open val isPlayable: Boolean get() = true

    open val displayName: String get() = name
    open val subtitle: String? get() = null

    val isInLibrary: Boolean get() = provider == "library"
    val isExplicit: Boolean get() = metadata?.explicit == true

    fun image(type: ImageType): ImageInfo? = images[type] ?: images[ImageType.MAIN]

    /**
     * The reference the server can resolve back to this item: `provider://media_type/item_id`,
     * the shape its own `create_uri` produces — use this, not [uri], for every command that
     * takes an item (play_media, library add, favorite add).
     *
     * [uri] is that shape for almost everything, but not always: the server's RSS podcast
     * parser overwrites a podcast's `uri` with whatever `<link>` the feed carries — the show's
     * *website* — and OpenSubsonic does the same with its radio stream URLs. Handed one of
     * those, `parse_uri` sees a plain http(s) URL, routes it to the builtin provider and
     * ffprobes a web page, which comes back as `InvalidDataError` ("Die angegebenen Daten sind
     * ungültig oder konnten nicht verarbeitet werden"). Hence the check that [uri] actually
     * addresses this item's provider before it is trusted; when it doesn't, the canonical form
     * is rebuilt from the parts the server did give us.
     */
    val referenceUri: String
        get() = uri?.takeIf { it.startsWith("$provider://") }
            ?: "$provider://${mediaType.serverValue}/$itemId"

    /**
     * URI suitable for the play_media API — [referenceUri], since a server-supplied [uri] is
     * not always resolvable (see there). Genres never carried one at all and used to override
     * this to synthesize the same shape by hand.
     */
    open val mediaUri: String?
        get() = referenceUri

    private val mappingsHashes: Set<Int> by lazy {
        providerMappings?.map { it.toHash().hashCode() }?.toSet() ?: emptySet()
    }

    fun hasAnyMappingFrom(other: AppMediaItem): Boolean =
        mappingsHashes.intersect(other.mappingsHashes).isNotEmpty()

    override fun equals(other: Any?): Boolean {
        return other is AppMediaItem &&
                itemId == other.itemId &&
                name == other.name &&
                mediaType == other.mediaType &&
                provider == other.provider &&
                favorite == other.favorite &&
                uri == other.uri
    }

    override fun hashCode(): Int {
        return mediaType.hashCode() +
                19 * itemId.hashCode() +
                31 * provider.hashCode() +
                37 * name.hashCode() +
                41 * (favorite?.hashCode() ?: 0) +
                43 * (uri?.hashCode() ?: 0)
    }

    override fun toString(): String =
        "AppMediaItem(" +
                "itemId='$itemId', " +
                "provider='$provider', " +
                "name='$name', " +
                "favorite=$favorite, " +
                "mediaType=$mediaType, " +
                "providerMappings=$providerMappings, " +
                "uri=$uri" +
                ")"
}

/** A quick favorite toggle is possible only when the add path has a [uri] to send. */
val AppMediaItem.canBeFavorited: Boolean get() = uri != null

fun PlayableItem.image(type: ImageType): ImageInfo? =
    images[type] ?: images[ImageType.MAIN] ?: images.firstNotNullOfOrNull { it.value }

val AudioFormat.description: String
    get() = listOfNotNull(
        contentType,
        sampleRate?.let { "$it Hz" },
        bitDepth?.let { "$it bit" },
    ).joinToString()

enum class QualityTier { HQ, SQ, LQ }

private val lossyContentTypes = setOf("mp3", "aac", "ogg", "opus", "vorbis", "m4a", "wma")

private fun AudioFormat.isLossy(): Boolean =
    contentType?.lowercase()?.let { ct -> lossyContentTypes.any { ct.contains(it) } } == true

private const val HI_RES_SAMPLE_RATE = 44_100
private const val HI_RES_BITRATE = 16

val AudioFormat.qualityTier: QualityTier?
    get() {
        val sr = sampleRate ?: return null
        val bd = bitDepth ?: return null
        if (sr < HI_RES_SAMPLE_RATE || bd < HI_RES_BITRATE) return QualityTier.LQ
        return if (isLossy()) QualityTier.SQ else QualityTier.HQ
    }

val QueueTrack.qualityTier: QualityTier?
    get() {
        val stages = listOfNotNull(format) +
                dsp?.values.orEmpty().mapNotNull { it.outputFormat }
        if (stages.isEmpty()) return null
        val tiers = stages.mapNotNull { it.qualityTier }
        if (tiers.isEmpty()) return null
        return when {
            QualityTier.LQ in tiers -> QualityTier.LQ
            QualityTier.SQ in tiers -> QualityTier.SQ
            else -> QualityTier.HQ
        }
    }

internal data class ProviderHash(val itemId: String, val providerInstance: String)

internal fun ProviderMapping.toHash(): ProviderHash = ProviderHash(itemId, providerInstance)
