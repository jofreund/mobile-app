package io.music_assistant.client.data.model.server

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Server-side queue payload. Non-critical fields default to safe values so an
 * older/newer server omitting a field doesn't abort the whole
 * `List<ServerQueue>` decode — one missing field on one queue would otherwise
 * throw `MissingFieldException` and take down the whole queue-listing RPC.
 */
@Serializable
data class ServerQueue(
    @SerialName("queue_id") val queueId: String,
    // @SerialName("active") val active: Boolean,
    // @SerialName("display_name") val displayName: String,
    @SerialName("available") val available: Boolean = false,
    // @SerialName("items") val items: Int,
    @SerialName("shuffle_enabled") val shuffleEnabled: Boolean = false,
    @SerialName("repeat_mode") val repeatMode: String? = null,
    /**
     * The current spelling of the setting this client long called "don't stop the music"; the
     * server renamed it to autoplay and now mirrors the value back into
     * [dontStopTheMusicEnabled] purely for clients that predate the rename. Nullable so its
     * absence doubles as the feature gate for the `player_queues/autoplay` command — see
     * [io.music_assistant.client.data.model.client.QueueInfo.supportsAutoplayCommand].
     */
    @SerialName("autoplay_enabled") val autoplayEnabled: Boolean? = null,
    /** Pre-rename spelling of [autoplayEnabled]; still the only one an older server sends. */
    @SerialName("dont_stop_the_music_enabled") val dontStopTheMusicEnabled: Boolean? = null,
    /**
     * Nullable as a feature gate, same reasoning as [playbackSpeed]: a server that never sends
     * `crossfade_enabled` has no crossfade to toggle, and the UI hides the control.
     */
    @SerialName("crossfade_enabled") val crossfadeEnabled: Boolean? = null,
    @SerialName("is_dynamic") val isDynamic: Boolean = false,
    @SerialName("current_index") val currentIndex: Int? = null,
    // @SerialName("index_in_buffer") val indexInBuffer: Int? = null,
    @SerialName("elapsed_time") val elapsedTime: Double? = null,
    /**
     * Unix epoch seconds (UTC) when [elapsedTime] was last recomputed.
     * Drives the staleness gate. Nullable so a missing field can't silently
     * drop subsequent legitimate events.
     */
    @SerialName("elapsed_time_last_updated") val elapsedTimeLastUpdated: Double? = null,
    /**
     * Current playback speed (1.0 = normal). Nullable on purpose: it doubles as a
     * feature-detect gate — servers without variable-speed support omit the field,
     * so `null` means "speed control unavailable" and the UI hides the speed button.
     */
    @SerialName("playback_speed") val playbackSpeed: Double? = null,
    // @SerialName("state") val state: PlayerState,
    @SerialName("current_item") val currentItem: ServerQueueItem? = null,
    // @SerialName("next_item") val nextItem: QueueItem? = null,
    @SerialName("radio_source") val radioSource: List<ServerMediaItem>? = null,
    // @SerialName("flow_mode") val flowMode: Boolean,
    // @SerialName("resume_pos") val resumePos: Double?
)
