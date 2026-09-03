package io.music_assistant.client.data

import io.music_assistant.client.api.APICommands
import io.music_assistant.client.api.Answer
import io.music_assistant.client.api.ConnectionInfo
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.data.factory.MediaItemFactory
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
import io.music_assistant.client.data.model.server.events.Event
import io.music_assistant.client.data.model.server.events.MediaItemPlayedData
import io.music_assistant.client.ui.compose.common.DataState
import io.music_assistant.client.ui.compose.common.action.PlayerAction
import io.music_assistant.client.utils.SessionState
import io.music_assistant.client.webrtc.DataChannelWrapper
import io.music_assistant.client.webrtc.model.RemoteId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins when a resume of a paused audiobook/episode is relocated to the server's resume
 * point and when it is left alone. The scenario it guards: pause a book here, listen on for
 * a while on another player, resume here — the resume must land where the listener actually
 * is, not where this queue stopped.
 */
class ResumePointResolverTest {
    private val bookUri = "library://audiobook/ab1"
    private val book = testAudiobook().copy(uri = bookUri)
    private val episode = testPodcastEpisode().copy(uri = "library://podcast_episode/ep1")

    private fun resolver(client: ServiceClient) = ResumePointResolver(client, MediaItemFactory(client))

    private fun resolve(
        item: PlayableItem,
        action: PlayerAction,
        isPlaying: Boolean = false,
        queueElapsedSec: Double? = 1200.0,
        serverResumeMs: Long? = 1_500_000,
        serverFullyPlayed: Boolean = false,
        ready: Boolean = true,
        client: FakeClient = FakeClient(ready) { itemAnswer(item, serverResumeMs, serverFullyPlayed) },
    ): Pair<PlayerAction, FakeClient> {
        val result = runBlocking {
            resolver(client).resolve(playerData(item, isPlaying, queueElapsedSec), action)
        }
        return result to client
    }

    @Test
    fun relocatesResumeWhenServerResumePointMovedAhead() {
        val (action, client) = resolve(book, PlayerAction.Play)

        assertEquals(PlayerAction.PlayFrom(1500L), action)
        val request = client.sent.single()
        assertEquals(APICommands.MUSIC_ITEM_BY_URI, request.command)
        assertEquals(bookUri, request.args?.get("uri")?.jsonPrimitive?.content)
    }

    @Test
    fun relocatesResumeWhenServerResumePointMovedBehind() {
        // The other player rewound; the server's point is still where the listener is.
        val (action, _) = resolve(book, PlayerAction.Play, serverResumeMs = 900_000)

        assertEquals(PlayerAction.PlayFrom(900L), action)
    }

    @Test
    fun toggleOnPausedPlayerIsAResume() {
        val (action, _) = resolve(book, PlayerAction.TogglePlayPause)

        assertEquals(PlayerAction.PlayFrom(1500L), action)
    }

    @Test
    fun podcastEpisodesRelocateToo() {
        val (action, _) = resolve(episode, PlayerAction.Play)

        assertEquals(PlayerAction.PlayFrom(1500L), action)
    }

    @Test
    fun keepsPlainResumeWithinTolerance() {
        // The queue's own pause wrote this point, give or take rounding: nothing moved.
        val (action, _) = resolve(book, PlayerAction.Play, serverResumeMs = 1_210_000)

        assertEquals(PlayerAction.Play, action)
    }

    @Test
    fun keepsPlainResumeWhenPlaying() {
        val (action, client) = resolve(book, PlayerAction.Play, isPlaying = true)

        assertEquals(PlayerAction.Play, action)
        assertTrue(client.sent.isEmpty(), "no lookup for a player that is already playing")
    }

    @Test
    fun toggleOnPlayingPlayerIsAPause() {
        val (action, client) = resolve(book, PlayerAction.TogglePlayPause, isPlaying = true)

        assertEquals(PlayerAction.TogglePlayPause, action)
        assertTrue(client.sent.isEmpty())
    }

    @Test
    fun pauseIsNeverRelocated() {
        val (action, client) = resolve(book, PlayerAction.Pause)

        assertEquals(PlayerAction.Pause, action)
        assertTrue(client.sent.isEmpty())
    }

    @Test
    fun plainTracksHaveNoResumePoint() {
        val (action, client) = resolve(testTrack().copy(uri = "library://track/1"), PlayerAction.Play)

        assertEquals(PlayerAction.Play, action)
        assertTrue(client.sent.isEmpty(), "no lookup for item types without a resume point")
    }

    @Test
    fun keepsPlainResumeWhenItemHasNoUri() {
        val (action, client) = resolve(testAudiobook(), PlayerAction.Play)

        assertEquals(PlayerAction.Play, action)
        assertTrue(client.sent.isEmpty())
    }

    @Test
    fun keepsPlainResumeWhenServerSaysFinished() {
        val (action, _) = resolve(book, PlayerAction.Play, serverFullyPlayed = true)

        assertEquals(PlayerAction.Play, action)
    }

    @Test
    fun keepsPlainResumeWhenServerHasNoPoint() {
        assertEquals(PlayerAction.Play, resolve(book, PlayerAction.Play, serverResumeMs = 0).first)
        assertEquals(PlayerAction.Play, resolve(book, PlayerAction.Play, serverResumeMs = null).first)
    }

    @Test
    fun keepsPlainResumeWhileOffline() {
        val (action, client) = resolve(book, PlayerAction.Play, ready = false)

        assertEquals(PlayerAction.Play, action)
        assertTrue(client.sent.isEmpty(), "must not sit on the readiness gate")
    }

    @Test
    fun keepsPlainResumeWhenLookupFails() {
        val failing = FakeClient(ready = true) { Result.failure(IllegalStateException("gone")) }
        val (action, _) = resolve(book, PlayerAction.Play, client = failing)

        assertEquals(PlayerAction.Play, action)
    }

    @Test
    fun keepsPlainResumeWhenServerRejects() {
        val rejecting = FakeClient(ready = true) {
            Result.success(Answer(buildJsonObject { put("error_code", JsonPrimitive(3)) }))
        }
        val (action, _) = resolve(book, PlayerAction.Play, client = rejecting)

        assertEquals(PlayerAction.Play, action)
    }

    @Test
    fun unknownQueuePositionCountsAsStart() {
        val (action, _) = resolve(book, PlayerAction.Play, queueElapsedSec = null)

        assertEquals(PlayerAction.PlayFrom(1500L), action)
    }

    // --- PlayFrom → request ---

    @Test
    fun playFromBuildsASeekAtItsPosition() {
        val factory = PlayerRequestFactory(PlayerPositionTracker(), UserPreferences())
        val request = factory.buildRequest(playerData(book, isPlaying = false, 0.0), PlayerAction.PlayFrom(1500L))

        assertEquals(APICommands.PLAYERS_CMD_SEEK, request?.command)
        assertEquals("1500", request?.args?.get("position")?.jsonPrimitive?.content)
        assertEquals("player-1", request?.args?.get("player_id")?.jsonPrimitive?.content)
    }

    // --- queuesFollowing ---

    private fun played(uri: String, secondsPlayed: Double = 1500.0, fullyPlayed: Boolean = false) =
        MediaItemPlayedData(
            uri = uri,
            name = "Book",
            duration = 36_000.0,
            secondsPlayed = secondsPlayed,
            fullyPlayed = fullyPlayed,
            isPlaying = false,
        )

    @Test
    fun pausedQueueShowingTheItemFollows() {
        val players = listOf(playerData(book, isPlaying = false, 1200.0))

        assertEquals(listOf("queue-1"), players.queuesFollowing(played(bookUri)))
    }

    @Test
    fun playingQueueDoesNotFollow() {
        // Its own time events anchor it; a report from elsewhere must not fight them.
        val players = listOf(playerData(book, isPlaying = true, 1200.0))

        assertTrue(players.queuesFollowing(played(bookUri)).isEmpty())
    }

    @Test
    fun otherItemsAndPlainTracksDoNotFollow() {
        val players = listOf(
            playerData(episode, isPlaying = false, 10.0),
            playerData(testTrack().copy(uri = bookUri), isPlaying = false, 10.0),
        )

        assertTrue(players.queuesFollowing(played(bookUri)).isEmpty())
    }

    @Test
    fun finishedItemDoesNotFollow() {
        val players = listOf(playerData(book, isPlaying = false, 1200.0))

        assertTrue(players.queuesFollowing(played(bookUri, fullyPlayed = true)).isEmpty())
    }

    // --- fixtures ---

    private fun itemAnswer(item: PlayableItem, resumeMs: Long?, fullyPlayed: Boolean): Result<Answer> =
        Result.success(
            Answer(
                buildJsonObject {
                    put("message_id", JsonPrimitive("1"))
                    put(
                        "result",
                        buildJsonObject {
                            put("item_id", JsonPrimitive(item.itemId))
                            put("provider", JsonPrimitive("library"))
                            put("name", JsonPrimitive("Book"))
                            put("media_type", JsonPrimitive(item.mediaType.serverValue))
                            item.uri?.let { put("uri", JsonPrimitive(it)) }
                            resumeMs?.let { put("resume_position_ms", JsonPrimitive(it)) }
                            put("fully_played", JsonPrimitive(fullyPlayed))
                        },
                    )
                },
            ),
        )

    private fun playerData(item: PlayableItem, isPlaying: Boolean, elapsedSec: Double?): PlayerData = PlayerData(
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
            queueId = "queue-1",
            isPlaying = isPlaying,
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
                    id = "queue-1",
                    available = true,
                    currentIndex = 0,
                    shuffleEnabled = false,
                    repeatMode = RepeatMode.OFF,
                    autoPlayEnabled = null,
                    elapsedTime = elapsedSec,
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

private class FakeClient(
    ready: Boolean,
    private val respondWith: (Request) -> Result<Answer>,
) : ServiceClient {
    val sent: MutableList<Request> = mutableListOf()

    override val isReadyForCommands: StateFlow<Boolean> = MutableStateFlow(ready)

    override suspend fun sendRequest(request: Request): Result<Answer> {
        sent.add(request)
        return respondWith(request)
    }

    override val sessionState: StateFlow<SessionState>
        get() = error("not used")
    override val events: Flow<Event<out Any>>
        get() = error("not used")
    override val foregroundEvents: Flow<Unit>
        get() = error("not used")
    override val webrtcSendspinChannel: DataChannelWrapper? = null
    override val webRTCHttpProxy: io.music_assistant.client.webrtc.WebRTCHttpProxy? = null

    override suspend fun login(username: String, password: String) = Unit
    override suspend fun authorize(token: String, isAutoLogin: Boolean) = Unit
    override fun logout() = Unit
    override fun resolveImageUrl(
        path: String,
        provider: String,
        isRemotelyAccessible: Boolean,
        proxyId: String?,
    ): String? = null
    override fun rebaseServerImageUrl(rawUrl: String): String? = null
    override fun forceWebRTCReconnect() = Unit
    override fun onAppForeground() = Unit
    override fun onAppBackground() = Unit
    override fun disconnectByUser() = Unit
    override fun connect(connection: ConnectionInfo) = Unit
    override fun connectWebRTC(remoteId: RemoteId) = Unit
    override fun onPlaybackActive() = Unit
    override fun onPlaybackInactive() = Unit
    override fun forceDisconnect(reason: Exception) = Unit
    override fun noServer() = Unit
}
