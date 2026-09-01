package io.music_assistant.client.data

import io.music_assistant.client.api.APICommands
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.PlayerDataFixtures
import io.music_assistant.client.data.model.client.Queue
import io.music_assistant.client.data.model.client.QueueInfo
import io.music_assistant.client.data.model.client.RepeatMode
import io.music_assistant.client.ui.compose.common.DataState
import io.music_assistant.client.ui.compose.common.action.PlayerAction
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins the two queue settings the expanded player's overflow menu drives.
 *
 * Autoplay is the setting the server renamed: `player_queues/dont_stop_the_music` survives
 * there only as an alias of `player_queues/autoplay`, and which one a given server understands
 * is answered by the queue payload itself ([QueueInfo.supportsAutoplayCommand]) rather than by
 * a pinned schema version. Crossfade is plain, but shares the "pass the current value, Kotlin
 * flips it" contract every other toggle uses — a factory that echoed the value back instead of
 * inverting it would leave the menu unable to switch anything off.
 */
class QueueSettingsRequestTest {
    private val factory = PlayerRequestFactory(PlayerPositionTracker(), UserPreferences())

    private fun dataWith(
        supportsAutoplayCommand: Boolean = true,
        autoPlayEnabled: Boolean? = false,
        crossfadeEnabled: Boolean? = false,
    ): PlayerData {
        val base = PlayerDataFixtures.playerData(queueId = QUEUE_ID)
        return base.copy(
            queue = DataState.Data(
                Queue(
                    info = QueueInfo(
                        id = QUEUE_ID,
                        available = true,
                        currentIndex = null,
                        shuffleEnabled = false,
                        repeatMode = RepeatMode.OFF,
                        autoPlayEnabled = autoPlayEnabled,
                        supportsAutoplayCommand = supportsAutoplayCommand,
                        crossfadeEnabled = crossfadeEnabled,
                        elapsedTime = null,
                        elapsedTimeLastUpdated = null,
                        currentItem = null,
                        radioSource = emptyList(),
                    ),
                    items = DataState.NoData(),
                ),
            ),
        )
    }

    @Test
    fun autoplayUsesTheCurrentCommandWhenTheServerReportsTheNewField() {
        val request = factory.buildRequest(dataWith(), PlayerAction.ToggleDontStopTheMusic(false))

        assertEquals(APICommands.PLAYER_QUEUES_AUTOPLAY, request?.command)
        assertEquals(JsonPrimitive(QUEUE_ID), request?.args?.get("queue_id"))
        assertEquals(JsonPrimitive(true), request?.args?.get("autoplay_enabled"))
    }

    @Test
    fun autoplayFallsBackToTheDeprecatedAliasOnAnOlderServer() {
        val data = dataWith(supportsAutoplayCommand = false)

        val request = factory.buildRequest(data, PlayerAction.ToggleDontStopTheMusic(false))

        assertEquals(APICommands.PLAYER_QUEUES_DONT_STOP_THE_MUSIC, request?.command)
        assertEquals(JsonPrimitive(true), request?.args?.get("dont_stop_the_music_enabled"))
    }

    @Test
    fun autoplayTurnsOffWhenItIsCurrentlyOn() {
        val data = dataWith(autoPlayEnabled = true)

        val request = factory.buildRequest(data, PlayerAction.ToggleDontStopTheMusic(true))

        assertEquals(JsonPrimitive(false), request?.args?.get("autoplay_enabled"))
    }

    @Test
    fun crossfadeTogglesTheCurrentValueOnTheQueue() {
        val request = factory.buildRequest(dataWith(), PlayerAction.ToggleCrossfade(false))

        assertEquals(APICommands.PLAYER_QUEUES_CROSSFADE, request?.command)
        assertEquals(JsonPrimitive(QUEUE_ID), request?.args?.get("queue_id"))
        assertEquals(JsonPrimitive(true), request?.args?.get("crossfade_enabled"))

        val off = factory.buildRequest(
            dataWith(crossfadeEnabled = true),
            PlayerAction.ToggleCrossfade(true),
        )
        assertEquals(JsonPrimitive(false), off?.args?.get("crossfade_enabled"))
    }

    @Test
    fun bothToggleTheirWayToNothingWithoutAQueue() {
        val noQueue = PlayerDataFixtures.playerData().copy(queue = DataState.NoData())

        assertNull(factory.buildRequest(noQueue, PlayerAction.ToggleDontStopTheMusic(false)))
        assertNull(factory.buildRequest(noQueue, PlayerAction.ToggleCrossfade(false)))
    }

    private companion object {
        const val QUEUE_ID = "queue-settings-1"
    }
}
