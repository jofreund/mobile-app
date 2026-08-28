package io.music_assistant.client.data

import kotlin.test.Test
import kotlin.test.assertEquals
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
}
