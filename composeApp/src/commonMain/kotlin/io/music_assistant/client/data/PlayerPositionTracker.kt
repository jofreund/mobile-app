package io.music_assistant.client.data

import io.music_assistant.client.utils.currentTimeMillis
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlin.math.abs

/**
 * Single source of truth for "what elapsed-time is each queue at, right now".
 *
 * Server events (`QueueTimeUpdatedEvent`, `QueueAddedEvent`, ...) write
 * anchors here, and user transport actions write *optimistic* anchors ahead of
 * the server (seek target, 0.0 on next/previous — see
 * `MainDataSource.applyOptimisticFeedback`), overwritten by the next server
 * anchor either way — except a seek target, which holds the playhead until a
 * server position reflects it (see [setSeekTarget]). Play/pause transitions
 * snapshot the interpolated position so the pause duration doesn't fold into
 * the next forward step. Consumers
 * (in-app slider, audiobook chapter logic) all read the same source —
 * synchronously via [effectiveSec] or as a smoothly-ticking flow via [observe].
 *
 * No background tick: the cold [observe] flow ticks at 500 ms only while a
 * collector is attached AND the queue is playing. Sync reads are O(1) map
 * lookups — no allocations, no ipc.
 */
class PlayerPositionTracker(
    /**
     * How long a seek target holds the playhead before a server position is believed
     * again regardless. Constructor-injected so tests can close the window.
     */
    private val seekSettleWindowMs: Long = SEEK_SETTLE_WINDOW_MS,
) {
    /** Anchor data for a single queue. */
    data class Anchor(
        val elapsedSec: Double,
        val wallMs: Long,
        val isPlaying: Boolean,
        val durationSec: Double?,
        /**
         * Media-seconds advanced per wall-second (1.0 = normal). Variable speed
         * (audiobooks/podcasts) makes media-time run faster/slower than the wall
         * clock; the server reports elapsed in media-time, so we must scale the
         * interpolated delta to match, or the slider drifts then snaps each anchor.
         */
        val speed: Double = 1.0,
        /** Hold the optimistic position until Sendspin confirms audio is flowing. */
        val freezeReason: FreezeReason? = null,
        /**
         * Position a user seek asked for, while it is still settling: server anchors
         * that do not reflect it yet are held off (see [setSeekTarget]). Null unless a
         * seek is settling.
         */
        val settleTargetSec: Double? = null,
        /** Wall-clock ms after which [settleTargetSec] stops holding server anchors off. */
        val settleDeadlineMs: Long? = null,
    ) {
        /**
         * Whether a server position of [elapsedSec] ends this anchor's hold: it reflects
         * the seek that is settling, or the hold has run out of patience. An anchor
         * waiting on Sendspin (no [settleTargetSec]) is never released this way — only
         * [confirmPlaying] speaks for it.
         */
        fun releasedBy(elapsedSec: Double): Boolean {
            val target = settleTargetSec ?: return false
            if (abs(elapsedSec - target) <= SEEK_SETTLE_TOLERANCE_SEC) return true
            return settleDeadlineMs != null && currentTimeMillis() >= settleDeadlineMs
        }

        /** Position right now: anchor + speed-scaled wall-time since anchor (capped at duration). */
        fun effectiveNow(): Double {
            if (!isPlaying || freezeReason != null) return elapsedSec
            val advanced = elapsedSec + (currentTimeMillis() - wallMs) / 1000.0 * speed
            return durationSec?.let { advanced.coerceAtMost(it) } ?: advanced
        }
    }

    /**
     * Optimistic anchors wait for [confirmPlaying], not server queue echoes: MA can
     * report the seek target or next-track position before Sendspin has audio.
     */
    enum class FreezeReason { SEEK, TRACK_CHANGE }

    private val anchors = MutableStateFlow<Map<String, Anchor>>(emptyMap())

    /**
     * Server-anchored update. Pass `isPlaying`/`durationSec` when known;
     * `null` preserves the existing values (useful for `QueueTimeUpdatedEvent`
     * which only carries the new elapsed value).
     */
    fun setAnchor(
        queueId: String,
        elapsedSec: Double,
        isPlaying: Boolean? = null,
        durationSec: Double? = null,
        speed: Double? = null,
    ) {
        anchors.update { existing ->
            val current = existing[queueId]
            // Server anchors are noisy during handoff; Sendspin sync is the confirmation.
            if (current?.freezeReason != null && !current.releasedBy(elapsedSec)) {
                return@update existing
            }
            existing + (
                queueId to Anchor(
                    elapsedSec = elapsedSec,
                    wallMs = currentTimeMillis(),
                    isPlaying = isPlaying ?: current?.isPlaying ?: false,
                    durationSec = durationSec ?: current?.durationSec,
                    speed = speed ?: current?.speed ?: 1.0,
                    freezeReason = null,
                )
            )
        }
    }

    /** User-dropped seek anchor; server echoes do not release the freeze. */
    fun setOptimisticSeek(
        queueId: String,
        elapsedSec: Double,
        durationSec: Double? = null,
        speed: Double? = null,
    ) {
        anchors.update { existing ->
            val current = existing[queueId]
            existing + (
                queueId to Anchor(
                    elapsedSec = elapsedSec,
                    wallMs = currentTimeMillis(),
                    isPlaying = current?.isPlaying ?: false,
                    durationSec = durationSec ?: current?.durationSec,
                    speed = speed ?: current?.speed ?: 1.0,
                    freezeReason = FreezeReason.SEEK,
                )
            )
        }
    }

    /**
     * User seek on a server-driven player: hold the playhead at [targetSec] until the
     * server reports a position that reflects it.
     *
     * A bare anchor is not enough. Seeking is not instant — Music Assistant flushes and
     * rebuilds the stream, which on a slow transport (an AirPlay speaker takes seconds)
     * keeps the old audio, and the old position, flowing meanwhile. Those queue updates
     * would overwrite the seek target within a second, dragging the playhead — and, in a
     * chaptered audiobook, the chapter the app shows — back to where the listener seeked
     * away from, so the seek reads as having been thrown away.
     *
     * The hold ends the moment a server position lands within [SEEK_SETTLE_TOLERANCE_SEC]
     * of the target, and in any case after [seekSettleWindowMs]: a server that never
     * applies the seek must not leave the playhead frozen on a fiction.
     */
    fun setSeekTarget(
        queueId: String,
        targetSec: Double,
        durationSec: Double? = null,
        speed: Double? = null,
    ) {
        anchors.update { existing ->
            val current = existing[queueId]
            existing + (
                queueId to Anchor(
                    elapsedSec = targetSec,
                    wallMs = currentTimeMillis(),
                    isPlaying = current?.isPlaying ?: false,
                    durationSec = durationSec ?: current?.durationSec,
                    speed = speed ?: current?.speed ?: 1.0,
                    freezeReason = FreezeReason.SEEK,
                    settleTargetSec = targetSec,
                    settleDeadlineMs = currentTimeMillis() + seekSettleWindowMs,
                )
            )
        }
    }

    /** Next/Previous boundary; wait for new-stream sync before ticking again. */
    fun setOptimisticTrackChange(
        queueId: String,
        elapsedSec: Double,
        durationSec: Double? = null,
        speed: Double? = null,
    ) {
        anchors.update { existing ->
            val current = existing[queueId]
            existing + (
                queueId to Anchor(
                    elapsedSec = elapsedSec,
                    wallMs = currentTimeMillis(),
                    isPlaying = current?.isPlaying ?: false,
                    durationSec = durationSec ?: current?.durationSec,
                    speed = speed ?: current?.speed ?: 1.0,
                    freezeReason = FreezeReason.TRACK_CHANGE,
                )
            )
        }
    }

    /** Release an optimistic freeze once Sendspin reports synchronized audio. */
    fun confirmPlaying(queueId: String) {
        anchors.update { existing ->
            val current = existing[queueId] ?: return@update existing
            if (current.freezeReason == null) return@update existing
            existing + (
                queueId to current.copy(
                    elapsedSec = current.effectiveNow(),
                    wallMs = currentTimeMillis(),
                    isPlaying = true,
                    freezeReason = null,
                    settleTargetSec = null,
                    settleDeadlineMs = null,
                )
            )
        }
    }

    /**
     * Play/pause transition. Snapshots the current interpolated position as
     * the new anchor so neither the slider nor MediaSession sees a jump:
     * - Pausing: anchor advances to "where we were", isPlaying=false → static.
     * - Resuming: same anchor, wallMs reset to now, isPlaying=true → forward.
     */
    fun setPlaying(queueId: String, isPlaying: Boolean) {
        anchors.update { existing ->
            val current = existing[queueId] ?: return@update existing
            if (current.isPlaying == isPlaying) return@update existing
            existing + (
                queueId to current.copy(
                    elapsedSec = current.effectiveNow(),
                    wallMs = currentTimeMillis(),
                    isPlaying = isPlaying,
                )
            )
        }
    }

    /** O(1) read of latest interpolated position. */
    fun effectiveSec(queueId: String): Double? = anchors.value[queueId]?.effectiveNow()

    /** True while an optimistic seek or track-change is waiting for confirmation. */
    fun isFrozenUntilConfirmed(queueId: String): Boolean =
        anchors.value[queueId]?.freezeReason != null

    /**
     * Cold flow of interpolated position. Emits immediately on subscription,
     * then either:
     * - re-emits on every anchor change (track flip, seek, server scrub,
     *   pause/resume), AND
     * - ticks at 500 ms while the queue is playing.
     *
     * Stops ticking when the queue is paused (waits for the next anchor
     * change). Cancels cleanly when the collector unsubscribes.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun observe(queueId: String): Flow<Double> = anchors
        .map { it[queueId] }
        .distinctUntilChanged()
        .flatMapLatest { anchor ->
            if (anchor == null) {
                flowOf(0.0)
            } else {
                flow {
                    while (currentCoroutineContext().isActive) {
                        emit(anchor.effectiveNow())
                        if (!anchor.isPlaying || anchor.freezeReason != null) break
                        delay(TICK_MS)
                    }
                }
            }
        }

    /** Drop a queue's anchor (e.g., when the queue is removed). */
    fun remove(queueId: String) {
        anchors.update { it - queueId }
    }

    /** Clear all anchors (disconnect / reset). */
    fun clear() {
        anchors.update { emptyMap() }
    }

    companion object {
        private const val TICK_MS = 500L

        /** How close a server position must land to a seek target to count as the seek. */
        const val SEEK_SETTLE_TOLERANCE_SEC = 2.0

        /**
         * Upper bound on the hold. Generous, because the server is slow to agree by design:
         * it flushes and rebuilds the stream to seek and waits up to five seconds for the
         * player to report playing before it even answers, and a slow transport (an AirPlay
         * speaker, more so a sync group of them) needs seconds more to have the new stream
         * running and its position reported against it. Shared with
         * `MainDataSource.SEEK_SETTLE_TIMEOUT_MS`, which waits for the same thing.
         */
        const val SEEK_SETTLE_WINDOW_MS = 15_000L
    }
}
