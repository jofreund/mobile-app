package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.Chapter
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.PlayerDataFixtures
import io.music_assistant.client.data.model.client.Queue
import io.music_assistant.client.data.model.client.QueueTrack
import io.music_assistant.client.data.model.client.items.PlayableItem
import io.music_assistant.client.data.model.client.testAudiobook
import io.music_assistant.client.data.model.client.testTrack
import io.music_assistant.client.data.model.server.ServerUserPreferences
import io.music_assistant.client.ui.compose.common.DataState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Guards [withPresentationChapter], the one place a surface turns absolute playback time
 * into the chapter-relative frame it draws.
 *
 * The domain stays absolute everywhere else — position anchors, seeks and the wire protocol
 * are all whole-book seconds — so the only thing that must be right here is when a chapter
 * is offered at all. Offering one for a plain track, or against the user's server preference,
 * silently rescales a scrubber that looks perfectly normal.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChapterPresentationTest {
    private val queueId = "queue-1"

    private val chapters = listOf(
        Chapter(position = 0, name = "Ch1", start = 0.0, end = 100.0),
        Chapter(position = 1, name = "Ch2", start = 100.0, end = 200.0),
    )

    private fun preferences(chapterProgress: Boolean) = UserPreferences().apply {
        update(ServerUserPreferences(audiobookChapterProgress = chapterProgress))
    }

    /** A tracker parked (paused) at [positionSec], so there is no wall-clock drift. */
    private fun trackerAt(positionSec: Double) = PlayerPositionTracker().apply {
        setAnchor(queueId = queueId, elapsedSec = positionSec, isPlaying = false)
    }

    /** [PlayerDataFixtures.playerData] with [item] installed as the current queue item. */
    private fun playerDataWith(item: PlayableItem): PlayerData {
        val base = PlayerDataFixtures.playerData(queueId = queueId)
        val info = (base.queue as DataState.Data<Queue>).data.info
        return base.copy(
            queue = DataState.Data(
                Queue(
                    info = info.copy(
                        currentIndex = 0,
                        currentItem = QueueTrack(
                            id = "queue-item-1",
                            track = item,
                            isPlayable = true,
                            format = null,
                            dsp = null,
                            provider = "test",
                        ),
                    ),
                    items = DataState.NoData(),
                ),
            ),
        )
    }

    private suspend fun resolve(
        item: PlayableItem,
        positionSec: Double,
        chapterProgress: Boolean = true,
    ): ChapterPresentation<PlayerData> {
        val data = playerDataWith(item)
        return flowOf(data)
            .withPresentationChapter(preferences(chapterProgress), trackerAt(positionSec)) { it }
            .first()
    }

    @Test
    fun offersTheContainingChapterForAnAudiobook() = runTest {
        val presentation = resolve(testAudiobook().copy(chapters = chapters), positionSec = 150.0)

        assertEquals("Ch2", presentation.chapter?.displayName)
        assertEquals(100.0, presentation.chapter?.start)
        assertEquals(100.0, presentation.chapter?.duration)
        assertEquals(150.0, presentation.elapsedSec)
    }

    @Test
    fun offersNoChapterWhenTheServerPreferenceIsOff() = runTest {
        val presentation = resolve(
            testAudiobook().copy(chapters = chapters),
            positionSec = 150.0,
            chapterProgress = false,
        )

        assertNull(
            presentation.chapter,
            "With the preference off the scrubber must stay on whole-book time",
        )
    }

    @Test
    fun offersNoChapterForAPlainTrack() = runTest {
        assertNull(resolve(testTrack(), positionSec = 150.0).chapter)
    }

    @Test
    fun offersNoChapterForAnAudiobookWithoutChapterMetadata() = runTest {
        assertNull(resolve(testAudiobook().copy(chapters = emptyList()), positionSec = 150.0).chapter)
    }

    @Test
    fun carriesThePositionTheChapterWasResolvedFrom() = runTest {
        // The pair matters: a consumer that re-read the tracker itself could render a chapter
        // and a position sampled a tick apart, which at a boundary disagree.
        val presentation = resolve(testAudiobook().copy(chapters = chapters), positionSec = 40.0)

        assertEquals("Ch1", presentation.chapter?.displayName)
        assertEquals(40.0, presentation.elapsedSec)
    }
}
