package io.music_assistant.client.data.announcement

import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.utils.DataConnectionState
import io.music_assistant.client.utils.SessionState
import io.music_assistant.client.utils.authenticatedToken
import io.music_assistant.client.utils.resultAs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/** What the signed-in server can announce. Voice is further hidden for the phone's own player. */
data class AnnouncementAvailability(val text: Boolean = false, val voice: Boolean = false)

/**
 * Typed and spoken announcements. Both run in the app [scope], not the caller's: the server
 * answers only after the announcement has played, and a spoken one would be cut short if its
 * link closed early.
 *
 * Ported from upstream (#1101) with one difference. Upstream's `speak` streams the microphone
 * live, so whatever was said before the button is released reaches the server — and the
 * server plays every clip that has audio in it, whatever happens to the link. The intercom tab
 * has to be able to send nothing (slide off the card, let go too early, a phone call), so this
 * fork records in Swift and sends the finished clip on release: [sendClip], over the same
 * protocol (`runLiveAnnouncement`). Upstream's `speak`, `LiveRecording` and `MicrophoneCapture`
 * are therefore not here.
 */
class AnnouncementRepository(
    private val apiClient: ServiceClient,
    private val httpClient: HttpClient,
    private val scope: CoroutineScope,
) {
    private val log = Logger.withTag("Announcement")

    @OptIn(ExperimentalCoroutinesApi::class)
    val availability: StateFlow<AnnouncementAvailability> = apiClient.sessionState
        .map { state -> state.authenticatedSchema() }
        .distinctUntilChanged()
        .mapLatest { schema ->
            schema?.let {
                AnnouncementAvailability(
                    // Older servers reject the engine query, and the error would reach the user.
                    text = it >= TEXT_SCHEMA && hasTtsEngine(),
                    voice = it >= VOICE_SCHEMA,
                )
            } ?: AnnouncementAvailability()
        }
        .stateIn(scope, SharingStarted.Eagerly, AnnouncementAvailability())

    /** The player's chime setting; null when the server does not say. */
    suspend fun chimeSetting(playerId: String): Boolean? =
        apiClient.sendRequest(Request.Player.announcementChime(playerId)).resultAs<Boolean>()

    fun type(playerId: String, message: String, options: AnnouncementOptions) {
        scope.launch {
            apiClient.sendRequest(
                Request.Player.playAnnouncement(playerId, message, options.preAnnounce, options.volumeLevel),
            )
        }
    }

    /**
     * Announces a finished recording — raw s16le mono [pcm] at [sampleRate] — on [playerId].
     *
     * [onAudioLeftDevice] fires once the whole clip and the stop have gone out: from then on the
     * server plays it whatever happens to the link. [onResult] fires once, after playback, or
     * as soon as it is clear the clip did not get through. Neither can be cancelled: a link
     * closed half-way through the clip announces the half that arrived.
     */
    fun sendClip(
        playerId: String,
        pcm: ByteArray,
        sampleRate: Int,
        options: AnnouncementOptions,
        onAudioLeftDevice: () -> Unit,
        onResult: (ClipResult) -> Unit,
    ) {
        scope.launch {
            val result = try {
                stream(playerId, pcm, sampleRate, options, onAudioLeftDevice)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.e(e) { "Recorded announcement failed" }
                ClipResult.notSent()
            }
            onResult(result)
        }
    }

    private suspend fun stream(
        playerId: String,
        pcm: ByteArray,
        sampleRate: Int,
        options: AnnouncementOptions,
        onAudioLeftDevice: () -> Unit,
    ): ClipResult {
        // An empty clip would reach the server as a mis-tap and play nothing; say so instead.
        if (pcm.isEmpty()) return ClipResult.notSent()
        val state = apiClient.sessionState.value
        val token = state.authenticatedToken() ?: return ClipResult.notSent()
        val link = when (state) {
            is SessionState.Connected.Direct ->
                WebSocketLink.connect(httpClient, state.connectionInfo.liveAnnouncementUrl)

            is SessionState.Connected.WebRTC ->
                apiClient.openWebRTCDataChannel(LIVE_ANNOUNCEMENT_CHANNEL)?.let(::DataChannelLink)

            else -> null
        } ?: return ClipResult.notSent()
        return runRecordedAnnouncement(link, token, playerId, pcm, sampleRate, options, onAudioLeftDevice)
    }

    private suspend fun hasTtsEngine(): Boolean =
        apiClient.sendRequest(Request.Player.ttsEngines()).resultAs<List<JsonObject>>()?.isNotEmpty() == true

    private fun SessionState.authenticatedSchema(): Int? =
        (this as? SessionState.Connected)
            ?.takeIf { it.dataConnectionState is DataConnectionState.Authenticated }
            ?.serverInfo?.schemaVersion

    internal companion object {
        const val TEXT_SCHEMA = 46
        const val VOICE_SCHEMA = 48
        const val LIVE_ANNOUNCEMENT_CHANNEL = "live_announcement"
    }
}
