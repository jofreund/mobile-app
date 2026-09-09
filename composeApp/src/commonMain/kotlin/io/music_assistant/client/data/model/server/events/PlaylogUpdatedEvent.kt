package io.music_assistant.client.data.model.server.events

import io.music_assistant.client.data.model.server.EventType
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The server's playlog entry for a media item changed — its resume position moved, or it
 * was marked (un)played.
 *
 * The narrower successor to [MediaItemPlayedEvent]: current servers announce a moved resume
 * point with this event, whose payload is the playlog entry itself rather than a description
 * of a play in progress. Both are decoded, since which one arrives depends on the server.
 */
@Serializable
data class PlaylogUpdatedEvent(
    @SerialName("event") override val event: EventType,
    @SerialName("object_id") override val objectId: String? = null,
    @SerialName("data") override val data: PlaylogUpdatedData,
) : Event<PlaylogUpdatedData>

@Serializable
data class PlaylogUpdatedData(
    @SerialName("uri") val uri: String,
    @SerialName("media_type") val mediaType: String? = null,
    @SerialName("seconds_played") val secondsPlayed: Double,
    @SerialName("fully_played") val fullyPlayed: Boolean,
    /** The user the change applies to; absent when it applies to every user. */
    @SerialName("userid") val userId: String? = null,
)
