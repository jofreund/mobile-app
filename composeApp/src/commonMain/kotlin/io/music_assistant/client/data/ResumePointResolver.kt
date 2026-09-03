package io.music_assistant.client.data

import co.touchlab.kermit.Logger
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.data.factory.MediaItemFactory
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.items.AppMediaItem
import io.music_assistant.client.data.model.client.items.Audiobook
import io.music_assistant.client.data.model.client.items.PlayableItem
import io.music_assistant.client.data.model.client.items.PodcastEpisode
import io.music_assistant.client.data.model.server.ServerMediaItem
import io.music_assistant.client.data.model.server.events.MediaItemPlayedData
import io.music_assistant.client.ui.compose.common.action.PlayerAction
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

/**
 * Keeps a paused audiobook or podcast episode in step with the resume point the server
 * stores for it.
 *
 * The server keeps one resume point per audiobook/episode and starts a *fresh* play of the
 * item there. Resuming a *paused* queue is different: it restarts from the queue's own
 * elapsed time. So a book paused here, listened to for a while on another player, and
 * resumed here would pick up where this queue stopped — behind where the listener actually
 * is, replaying what they already heard.
 *
 * [resolve] closes that gap before the resume is sent: it asks the server for the item's
 * current resume point and, when that has moved away from the queue's own position, turns
 * the resume into a [PlayerAction.PlayFrom] there. A seek starts playback server-side, so it
 * doubles as the resume and nothing else has to change.
 *
 * Best-effort and bounded: an unreachable server, a slow answer or an unexpected payload
 * leaves the plain resume in place rather than holding it up.
 */
class ResumePointResolver(
    private val apiClient: ServiceClient,
    private val mediaItemFactory: MediaItemFactory,
) {
    private val log = Logger.withTag("ResumePointResolver")

    /**
     * [action] unchanged unless it resumes a paused audiobook/episode whose server resume
     * point has drifted from the queue's position — then the [PlayerAction.PlayFrom] that
     * lands on the server's point instead.
     *
     * Compares against the queue's *server-reported* elapsed time, not the live tracker
     * anchor: the server resumes a paused queue from the former, and the tracker may already
     * have been moved to the resume point by [queuesFollowing] while paused.
     */
    suspend fun resolve(data: PlayerData, action: PlayerAction): PlayerAction {
        if (!action.resumesPlayback(data)) return action
        val queueInfo = data.queueInfo ?: return action
        val item = queueInfo.currentItem?.track?.takeIf { it.hasResumePoint() } ?: return action
        val uri = item.uri ?: return action
        // Offline: the request would sit on the readiness gate; the plain resume is queued
        // and replayed anyway, and this runs again on the next play.
        if (!apiClient.isReadyForCommands.value) return action

        val serverSec = fetchResumePointSec(uri) ?: return action
        val queueSec = queueInfo.elapsedTime ?: 0.0
        if (abs(serverSec - queueSec) <= RESUME_DRIFT_TOLERANCE_SEC) return action
        log.i {
            "Resume point for '${item.displayName}' is at ${serverSec}s, queue at ${queueSec}s — resuming there"
        }
        return PlayerAction.PlayFrom(serverSec.toLong())
    }

    private suspend fun fetchResumePointSec(uri: String): Double? =
        withTimeoutOrNull(FETCH_TIMEOUT_MS) {
            apiClient.sendRequest(Request.Library.getByUri(uri))
                .getOrNull()
                ?.resultAs<ServerMediaItem>()
                ?.let(mediaItemFactory::create)
                ?.resumePointSec()
        }

    private companion object {
        /**
         * The queue's own pause writes the same resume point the server hands back, give or
         * take the rounding of both; only a real move by another player should relocate.
         */
        const val RESUME_DRIFT_TOLERANCE_SEC = 15.0

        /** Well inside the local player's pending-play backstop, so a slow answer can't strand it. */
        const val FETCH_TIMEOUT_MS = 3_000L
    }
}

/** Only audiobooks and podcast episodes carry a server-side resume point. */
internal fun PlayableItem.hasResumePoint(): Boolean = this is Audiobook || this is PodcastEpisode

/**
 * The stored resume point in seconds, or null when there is nothing to resume from: a
 * finished item, an unset or zero position, or an item type without one.
 */
internal fun AppMediaItem.resumePointSec(): Double? =
    when (this) {
        is Audiobook -> resumePositionMs.takeUnless { fullyPlayed == true }
        is PodcastEpisode -> resumePositionMs.takeUnless { fullyPlayed == true }
        else -> null
    }?.takeIf { it > 0 }?.let { it / MS_PER_SEC }

/** Play, or a toggle that means play, on a player that is not playing. */
private fun PlayerAction.resumesPlayback(data: PlayerData): Boolean =
    !data.player.isPlaying &&
        (this == PlayerAction.Play || this == PlayerAction.TogglePlayPause)

/**
 * Ids of the queues whose paused player is showing the audiobook/episode that [played]
 * reports progress for — another player is moving its resume point, and their displayed
 * position should follow so the slider shows where a resume will actually pick up.
 * A finished item is left alone: its resume point is gone, not moved.
 */
internal fun List<PlayerData>.queuesFollowing(played: MediaItemPlayedData): List<String> =
    if (played.fullyPlayed) {
        emptyList()
    } else {
        mapNotNull { data ->
            data.queueInfo
                ?.takeUnless { data.player.isPlaying }
                ?.takeIf { queue ->
                    queue.currentItem?.track?.let { it.hasResumePoint() && it.uri == played.uri } == true
                }
                ?.id
        }
    }

private const val MS_PER_SEC = 1_000.0
