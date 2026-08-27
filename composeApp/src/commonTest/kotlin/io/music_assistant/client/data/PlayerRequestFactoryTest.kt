package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.Chapter
import io.music_assistant.client.data.model.client.Metadata
import io.music_assistant.client.data.model.client.Player
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.PlayerType
import io.music_assistant.client.data.model.client.Queue
import io.music_assistant.client.data.model.client.QueueInfo
import io.music_assistant.client.data.model.client.QueueTrack
import io.music_assistant.client.data.model.client.RepeatMode
import io.music_assistant.client.data.model.client.items.PlayableItem
import io.music_assistant.client.data.model.client.testAudiobook
import io.music_assistant.client.data.model.client.testPodcastEpisode
import io.music_assistant.client.data.model.client.testTrack
import io.music_assistant.client.data.model.server.ServerUserPreferences
import io.music_assistant.client.ui.compose.common.DataState
import io.music_assistant.client.ui.compose.common.action.PlayerAction
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins [PlayerRequestFactory.resolve] for chapter jumps. The regression it guards: an
 * optimistic update that freezes the tracked position to 0.0 *before* the request is
 * built made chapter resolution always seek to chapter 2. Moving the resolution into
 * `resolve()` — which runs first and reads the *live* position — is what these tests
 * lock in.
 *
 * Also pins the two things chapter navigation is gated on: the media type (audiobooks
 * and podcast episodes, nothing else) and the server's `audiobook_chapter_progress`
 * preference.
 */
class PlayerRequestFactoryTest {
    private val queueId = "queue-1"

    // Chapters at 0/100/200/300 s; each 100 s long.
    private fun audiobookWithChapters(): PlayableItem = testAudiobook().copy(chapters = chapterList)

    private val chapterList = listOf(
        Chapter(position = 0, name = "Ch1", start = 0.0, end = 100.0),
        Chapter(position = 1, name = "Ch2", start = 100.0, end = 200.0),
        Chapter(position = 2, name = "Ch3", start = 200.0, end = 300.0),
        Chapter(position = 3, name = "Ch4", start = 300.0, end = 400.0),
    )

    /** A podcast episode carries its chapters on [Metadata], not as a first-class field. */
    private fun podcastWithChapters(): PlayableItem = testPodcastEpisode().copy(
        metadata = Metadata(
            explicit = false,
            images = emptyList(),
            releaseDate = null,
            chapters = chapterList,
            lyrics = null,
            lrcLyrics = null,
        ),
    )

    /**
     * Resolve [action] with the shared tracker parked (paused) at [positionSec].
     *
     * [chapterProgress] stands in for the server's `audiobook_chapter_progress` preference.
     */
    private fun resolveAt(
        positionSec: Double,
        item: PlayableItem,
        action: PlayerAction,
        chapterProgress: Boolean = true,
    ): PlayerAction {
        val tracker = PlayerPositionTracker()
        // Paused anchor → effectiveSec returns exactly positionSec (no wall-clock drift).
        tracker.setAnchor(queueId = queueId, elapsedSec = positionSec, isPlaying = false)
        val preferences = UserPreferences().apply {
            update(ServerUserPreferences(audiobookChapterProgress = chapterProgress))
        }
        return PlayerRequestFactory(tracker, preferences).resolve(playerDataWith(item), action)
    }

    @Test
    fun nextInsideChapterSeeksToNextChapterStartNotChapterTwo() {
        // Playing 50 s into chapter 2 (100..200). Must advance to chapter 3 (200),
        // not collapse to chapter 2 from a zeroed position.
        assertEquals(PlayerAction.SeekTo(200L), resolveAt(150.0, audiobookWithChapters(), PlayerAction.Next))
    }

    @Test
    fun nextPastLastChapterFallsThroughToNextCommand() {
        // No later chapter → keep the bare Next; buildRequest then emits a plain `next`.
        assertEquals(PlayerAction.Next, resolveAt(350.0, audiobookWithChapters(), PlayerAction.Next))
    }

    @Test
    fun nextOnNonAudiobookFallsThroughToNextCommand() {
        assertEquals(PlayerAction.Next, resolveAt(150.0, testTrack(), PlayerAction.Next))
    }

    @Test
    fun previousDeepIntoChapterRestartsCurrentChapter() {
        // 50 s into chapter 2 (> 5 s grace) → restart chapter 2 (100).
        assertEquals(PlayerAction.SeekTo(100L), resolveAt(150.0, audiobookWithChapters(), PlayerAction.Previous))
    }

    @Test
    fun previousWithinGraceGoesToPreviousChapter() {
        // 2 s into chapter 2 (<= 5 s grace) → jump back to chapter 1 (0).
        assertEquals(PlayerAction.SeekTo(0L), resolveAt(102.0, audiobookWithChapters(), PlayerAction.Previous))
    }

    @Test
    fun previousOnNonAudiobookFallsThroughToPreviousCommand() {
        assertEquals(PlayerAction.Previous, resolveAt(150.0, testTrack(), PlayerAction.Previous))
    }

    @Test
    fun nextOnAPodcastEpisodeSeeksToTheNextChapter() {
        // Podcast chapters live on Metadata rather than a first-class field, and used to be
        // ignored entirely — Next fell through to the next episode from mid-chapter.
        assertEquals(
            PlayerAction.SeekTo(200L),
            resolveAt(150.0, podcastWithChapters(), PlayerAction.Next),
        )
    }

    @Test
    fun previousOnAPodcastEpisodeRestartsTheCurrentChapter() {
        assertEquals(
            PlayerAction.SeekTo(100L),
            resolveAt(150.0, podcastWithChapters(), PlayerAction.Previous),
        )
    }

    @Test
    fun chapterNavigationOffFallsThroughToPlainCommands() {
        // The web frontend owns this toggle; with it off, Next/Previous must mean the next
        // and previous queue item, exactly as they do for a track.
        assertEquals(
            PlayerAction.Next,
            resolveAt(150.0, audiobookWithChapters(), PlayerAction.Next, chapterProgress = false),
        )
        assertEquals(
            PlayerAction.Previous,
            resolveAt(150.0, audiobookWithChapters(), PlayerAction.Previous, chapterProgress = false),
        )
    }

    @Test
    fun previousInTheFirstChapterClampsToTheStartRatherThanLeavingTheItem() {
        // Inside a chaptered book Previous means "the boundary behind me", and behind the
        // first chapter is the start of the book — not the previous queue item.
        assertEquals(
            PlayerAction.SeekTo(0L),
            resolveAt(2.0, audiobookWithChapters(), PlayerAction.Previous),
        )
    }

    @Test
    fun aFractionalChapterStartRoundsUpSoTheSeekLandsInsideIt() {
        // Truncating 100.5 to 100 lands in the previous chapter, which reads as the jump
        // having gone to the wrong chapter.
        val fractional = testAudiobook().copy(
            chapters = listOf(
                Chapter(position = 0, name = "Ch1", start = 0.0, end = 100.5),
                Chapter(position = 1, name = "Ch2", start = 100.5, end = 200.0),
            ),
        )
        assertEquals(PlayerAction.SeekTo(101L), resolveAt(50.0, fractional, PlayerAction.Next))
    }

    private fun playerDataWith(item: PlayableItem): PlayerData = PlayerData(
        player = Player(
            id = "player-1",
            name = "Test player",
            provider = "test",
            type = PlayerType.PLAYER,
            shouldBeShown = true,
            canSetVolume = false,
            canPower = false,
            isPowered = true,
            volumeLevel = null,
            volumeControl = null,
            volumeMuted = false,
            canMute = false,
            queueId = queueId,
            isPlaying = true,
            isAnnouncing = false,
            canGroupWith = null,
            groupMembers = null,
            staticGroupMembers = null,
            activeGroup = null,
            syncedTo = null,
            groupVolume = null,
            groupVolumeMuted = false,
            currentMedia = null,
        ),
        queue = DataState.Data(
            Queue(
                info = QueueInfo(
                    id = queueId,
                    available = true,
                    currentIndex = 0,
                    shuffleEnabled = false,
                    repeatMode = RepeatMode.OFF,
                    autoPlayEnabled = null,
                    elapsedTime = null,
                    elapsedTimeLastUpdated = null,
                    currentItem = QueueTrack(
                        id = "queue-item-1",
                        track = item,
                        isPlayable = true,
                        format = null,
                        dsp = null,
                        provider = "test",
                    ),
                    radioSource = emptyList(),
                ),
                items = DataState.NoData(),
            ),
        ),
        parentBind = null,
        childrenBinds = emptyList(),
    )
}
