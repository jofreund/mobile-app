package io.music_assistant.client.data

import io.ktor.client.HttpClient
import io.music_assistant.client.utils.NetworkMonitor
import io.music_assistant.client.utils.audioDispatcher
import io.music_assistant.client.utils.sendspinClock
import io.music_assistant.sendspin.SendspinPlayer
import io.music_assistant.sendspin.api.AudioSink
import io.music_assistant.sendspin.api.DecoderFactory
import io.music_assistant.sendspin.api.DeviceInfo
import io.music_assistant.sendspin.api.LocalPlayerConfig
import io.music_assistant.sendspin.api.SendspinDeps
import io.music_assistant.sendspin.api.SendspinKeyStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.StateFlow
import io.music_assistant.sendspin.api.SendspinPlayer as SendspinPlayerApi

/**
 * The platform half of the local player: the audio output and the decoders the
 * `:sendspin-kmp` module leaves to the app, plus the app version it reports in its hello.
 * iOS builds these in `MainViewController` and hands them to `AppGraph`.
 *
 * [sink] takes the remote-command callback because the native player is also the
 * lock screen's command source; the graph wires it to [LocalPlayerAdapter.onRemoteCommand].
 */
class LocalPlayerPorts(
    val sink: (onRemoteCommand: (String) -> Unit) -> AudioSink,
    val decoders: DecoderFactory,
    val softwareVersion: String,
)

/**
 * Builds the local player for [LocalPlayerAdapter]. The adapter owns the config
 * flow and the pairing callback; the platform ports live here, so a test can
 * hand the adapter a fake player instead.
 */
fun interface LocalPlayerFactory {
    fun create(
        config: StateFlow<LocalPlayerConfig?>,
        approvePairing: suspend (pairingToken: String) -> Unit,
        scope: CoroutineScope,
    ): SendspinPlayerApi
}

/** The production player: the `:sendspin-kmp` module over the platform sink, decoders and key store. */
class SendspinLocalPlayerFactory(
    private val sink: AudioSink,
    private val decoders: DecoderFactory,
    private val keyStore: SendspinKeyStore,
    private val networkMonitor: NetworkMonitor,
    private val httpClient: () -> HttpClient,
    private val softwareVersion: String,
) : LocalPlayerFactory {
    override fun create(
        config: StateFlow<LocalPlayerConfig?>,
        approvePairing: suspend (pairingToken: String) -> Unit,
        scope: CoroutineScope,
    ): SendspinPlayerApi = SendspinPlayer(
        config = config,
        deps = SendspinDeps(
            sink = sink,
            decoders = decoders,
            keyStore = keyStore,
            httpClient = httpClient(),
            online = networkMonitor.isAvailable,
            approvePairing = approvePairing,
            audioDispatcher = audioDispatcher,
            deviceInfo = DeviceInfo(
                productName = "Mobile Application",
                manufacturer = "Music Assistant",
                softwareVersion = softwareVersion,
            ),
            clock = sendspinClock,
        ),
        scope = scope,
    )
}
