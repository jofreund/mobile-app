package io.music_assistant.client.data.announcement

import kotlinx.coroutines.channels.Channel

/**
 * How a recorded announcement ended. Flat, with plain Booleans, because it crosses the bridge.
 *
 * The two progress flags are what the caller needs to decide whether a resend is safe: the
 * server plays every clip that has audio in it, also when the link goes away half-way.
 */
data class ClipResult(
    /** The server reported that the clip has played. */
    val played: Boolean,
    /** The server's own words, when it gave any. */
    val reason: String?,
    /** Audio reached the link: from here a failure may still play some or all of the clip. */
    val audioSent: Boolean,
    /** The whole clip and the stop went out: the server plays it whatever the link does now. */
    val stopSent: Boolean,
) {
    internal companion object {
        /** Nothing went out — no session, no link, no token, or an empty clip. */
        fun notSent() = ClipResult(played = false, reason = null, audioSent = false, stopSent = false)
    }
}

/**
 * Runs one finished clip through `runLiveAnnouncement`: the clip is cut into frames up front
 * and the frame channel closed, so the protocol streams all of it once the server has said
 * `started` and then sends the stop. [onAudioLeftDevice] fires right after that stop.
 *
 * This is the fork's half of announcements (see [AnnouncementRepository]); the protocol itself
 * is upstream's and runs unchanged.
 */
internal suspend fun runRecordedAnnouncement(
    link: AnnouncementLink,
    token: String,
    playerId: String,
    pcm: ByteArray,
    sampleRate: Int,
    options: AnnouncementOptions,
    onAudioLeftDevice: () -> Unit,
): ClipResult {
    val tracking = TrackingLink(link, onStop = onAudioLeftDevice)
    val frames = Channel<ByteArray>(Channel.UNLIMITED)
    pcm.frames().forEach { frames.trySend(it) }
    frames.close()
    val outcome = runLiveAnnouncement(tracking, token, playerId, sampleRate, options, frames)
    return ClipResult(
        played = outcome == LiveAnnouncementOutcome.Finished,
        reason = (outcome as? LiveAnnouncementOutcome.Failed)?.reason,
        audioSent = tracking.audioSent,
        stopSent = tracking.stopSent,
    )
}

/**
 * The options with the chime decided: the caller's choice when it made one, else [setting] —
 * the player's own `tts_pre_announce` — else on, which is that setting's default.
 *
 * Never left unset. The server reads the player's chime setting only for a spoken *text*;
 * a recorded clip that arrives without `pre_announce` plays with no chime at all, whatever
 * the player is set to. Upstream's dialog sends the setting explicitly for the same reason.
 */
internal fun AnnouncementOptions.withChime(setting: Boolean?): AnnouncementOptions =
    if (preAnnounce != null) this else copy(preAnnounce = setting ?: true)

/** The clip in frames of at most [FRAME_BYTES]; an even size, so no sample is split. */
internal fun ByteArray.frames(): List<ByteArray> =
    (indices step FRAME_BYTES).map { start -> copyOfRange(start, minOf(start + FRAME_BYTES, size)) }

/**
 * Notes how far a clip got. `runLiveAnnouncement` sends auth and start as text, then the
 * audio as binary, then the stop as text — so the first text after any audio is the stop.
 */
internal class TrackingLink(
    private val inner: AnnouncementLink,
    private val onStop: () -> Unit,
) : AnnouncementLink by inner {
    var audioSent = false
        private set
    var stopSent = false
        private set

    override suspend fun sendBinary(bytes: ByteArray) {
        // Set first: a send that fails half-way may still have delivered part of the frame.
        audioSent = true
        inner.sendBinary(bytes)
    }

    override suspend fun sendText(text: String) {
        inner.sendText(text)
        if (audioSent && !stopSent) {
            stopSent = true
            onStop()
        }
    }
}

/** 16 KiB: well inside what a WebRTC data channel carries in one message. */
private const val FRAME_BYTES = 16 * 1024
