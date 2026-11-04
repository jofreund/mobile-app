package io.music_assistant.client.data

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlayerPositionTrackerTest {
    @Test
    fun pausedAnchorReportsItsElapsedExactly() {
        val tracker = PlayerPositionTracker()
        val queueId = "queue"

        tracker.setAnchor(
            queueId = queueId,
            elapsedSec = 65.0,
            isPlaying = false,
            durationSec = 218.0,
            speed = 1.0,
        )

        assertEquals(65.0, tracker.effectiveSec(queueId))
    }

    @Test
    fun newerAnchorOverwritesOlderOne() {
        // The optimistic transport anchors (seek target, 0.0 on next/previous) rely on
        // exactly this: whoever wrote last wins, and the next server anchor corrects.
        val tracker = PlayerPositionTracker()
        val queueId = "queue"

        tracker.setAnchor(queueId = queueId, elapsedSec = 65.0, isPlaying = false)
        tracker.setAnchor(queueId = queueId, elapsedSec = 149.0)

        assertEquals(149.0, tracker.effectiveSec(queueId))
    }

    @Test
    fun playingAnchorNeverRunsPastDuration() {
        val tracker = PlayerPositionTracker()
        val queueId = "queue"

        tracker.setAnchor(
            queueId = queueId,
            elapsedSec = 218.0,
            isPlaying = true,
            durationSec = 218.0,
        )

        assertEquals(218.0, tracker.effectiveSec(queueId))
    }

    @Test
    fun elapsedOnlyAnchorPreservesPlayingStateAndDuration() {
        // QueueTimeUpdatedEvent carries only the new elapsed value.
        val tracker = PlayerPositionTracker()
        val queueId = "queue"

        tracker.setAnchor(
            queueId = queueId,
            elapsedSec = 60.0,
            isPlaying = true,
            durationSec = 100.0,
        )
        tracker.setAnchor(queueId = queueId, elapsedSec = 100.0)

        // Still playing (would advance), still capped by the preserved duration.
        val pos = tracker.effectiveSec(queueId) ?: error("missing position")
        assertEquals(100.0, pos)
    }

    @Test
    fun setPlayingOnUnknownQueueIsIgnored() {
        val tracker = PlayerPositionTracker()

        tracker.setPlaying("queue", isPlaying = true)

        assertNull(tracker.effectiveSec("queue"))
    }

    @Test
    fun removeAndClearDropAnchors() {
        val tracker = PlayerPositionTracker()

        tracker.setAnchor(queueId = "a", elapsedSec = 1.0)
        tracker.setAnchor(queueId = "b", elapsedSec = 2.0)

        tracker.remove("a")
        assertNull(tracker.effectiveSec("a"))
        assertTrue(tracker.effectiveSec("b") != null)

        tracker.clear()
        assertNull(tracker.effectiveSec("b"))
    }

    @Test
    fun seekTargetHoldsOffThePositionsArrivingWhileTheSeekIsStillBeingApplied() {
        // The HomePod case: seeking takes seconds on a slow transport, and the queue keeps
        // reporting the pre-seek position meanwhile. Believing one of those puts an
        // audiobook back in the chapter the listener just left.
        val tracker = PlayerPositionTracker()
        val queueId = "queue"

        tracker.setAnchor(queueId = queueId, elapsedSec = 93.0, isPlaying = true)
        tracker.setSeekTarget(queueId = queueId, targetSec = 1800.0)
        tracker.setAnchor(queueId = queueId, elapsedSec = 94.0)

        assertEquals(1800.0, tracker.effectiveSec(queueId))
        assertTrue(tracker.isFrozenUntilConfirmed(queueId))
    }

    @Test
    fun seekTargetReleasesOnTheServerPositionThatReflectsIt() {
        val tracker = PlayerPositionTracker()
        val queueId = "queue"

        tracker.setSeekTarget(queueId = queueId, targetSec = 1800.0)
        tracker.setAnchor(queueId = queueId, elapsedSec = 1801.0, isPlaying = false)

        assertEquals(1801.0, tracker.effectiveSec(queueId))
        assertFalse(tracker.isFrozenUntilConfirmed(queueId))
    }

    @Test
    fun seekTargetStopsHoldingOnceTheWindowIsSpent() {
        // A server that never applies the seek must not leave the playhead on a fiction.
        val tracker = PlayerPositionTracker(seekSettleWindowMs = 0)
        val queueId = "queue"

        tracker.setSeekTarget(queueId = queueId, targetSec = 1800.0)
        tracker.setAnchor(queueId = queueId, elapsedSec = 94.0, isPlaying = false)

        assertEquals(94.0, tracker.effectiveSec(queueId))
        assertFalse(tracker.isFrozenUntilConfirmed(queueId))
    }

    @Test
    fun localPlayerSeekStillWaitsForSendspinRatherThanAServerEcho() {
        // setOptimisticSeek carries no settle target: only confirmPlaying speaks for it,
        // however close a server position lands to the seek.
        val tracker = PlayerPositionTracker(seekSettleWindowMs = 0)
        val queueId = "queue"

        tracker.setOptimisticSeek(queueId = queueId, elapsedSec = 1800.0)
        tracker.setAnchor(queueId = queueId, elapsedSec = 1800.0)

        assertTrue(tracker.isFrozenUntilConfirmed(queueId))

        tracker.confirmPlaying(queueId)
        assertFalse(tracker.isFrozenUntilConfirmed(queueId))
    }

    @Test
    fun anUnconfirmedTrackChangeFallsBackToTheServerPosition() {
        // A next on the last item: the server changes nothing and sends nothing.
        val tracker = PlayerPositionTracker()
        val queueId = "queue"
        tracker.setAnchor(queueId = queueId, elapsedSec = 1800.0, isPlaying = false)

        val freezeId = tracker.setOptimisticTrackChange(queueId = queueId, elapsedSec = 0.0)
        assertEquals(0.0, tracker.effectiveSec(queueId))

        tracker.releaseUnconfirmed(queueId, freezeId)

        assertFalse(tracker.isFrozenUntilConfirmed(queueId))
        assertEquals(1800.0, tracker.effectiveSec(queueId))
    }

    @Test
    fun anUnconfirmedFreezeFallsBackToTheLatestServerPosition() {
        val tracker = PlayerPositionTracker()
        val queueId = "queue"
        tracker.setAnchor(queueId = queueId, elapsedSec = 65.0, isPlaying = false)
        val freezeId = tracker.setOptimisticSeek(queueId = queueId, elapsedSec = 149.0)

        // A rejected seek: the server keeps reporting its own position.
        tracker.setAnchor(queueId = queueId, elapsedSec = 70.0)
        assertEquals(149.0, tracker.effectiveSec(queueId))

        tracker.releaseUnconfirmed(queueId, freezeId)

        assertEquals(70.0, tracker.effectiveSec(queueId))
    }

    @Test
    fun aConfirmedFreezeStillWaitsForAudio() {
        val tracker = PlayerPositionTracker()
        val queueId = "queue"
        tracker.setAnchor(queueId = queueId, elapsedSec = 65.0, isPlaying = true)
        val freezeId = tracker.setOptimisticSeek(queueId = queueId, elapsedSec = 149.0)

        // The echo of the seek target, then a noisy old position during the handoff.
        tracker.setAnchor(queueId = queueId, elapsedSec = 149.0)
        tracker.setAnchor(queueId = queueId, elapsedSec = 66.0)
        tracker.releaseUnconfirmed(queueId, freezeId)

        assertTrue(tracker.isFrozenUntilConfirmed(queueId))
        assertEquals(149.0, tracker.effectiveSec(queueId))
    }

    @Test
    fun releasingAnOlderFreezeKeepsTheNewerOne() {
        val tracker = PlayerPositionTracker()
        val queueId = "queue"
        tracker.setAnchor(queueId = queueId, elapsedSec = 65.0, isPlaying = false)
        val older = tracker.setOptimisticSeek(queueId = queueId, elapsedSec = 95.0)
        tracker.confirmPlaying(queueId)
        tracker.setPlaying(queueId, isPlaying = false)
        val newer = tracker.setOptimisticSeek(queueId = queueId, elapsedSec = 125.0)

        tracker.releaseUnconfirmed(queueId, older)

        assertTrue(newer != older)

        assertTrue(tracker.isFrozenUntilConfirmed(queueId))
        assertEquals(125.0, tracker.effectiveSec(queueId))
    }
}
