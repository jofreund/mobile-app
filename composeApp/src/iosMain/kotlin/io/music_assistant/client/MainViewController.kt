@file:OptIn(
    kotlinx.cinterop.ExperimentalForeignApi::class,
    kotlinx.cinterop.BetaInteropApi::class,
    kotlin.experimental.ExperimentalNativeApi::class,
    io.ktor.utils.io.ExperimentalKtorApi::class,
)

package io.music_assistant.client

import io.ktor.client.webrtc.IosWebRtc
import io.ktor.client.webrtc.WebRtcClient
import io.music_assistant.client.data.LocalPlayerPorts
import io.music_assistant.client.di.AppGraph
import io.music_assistant.client.logging.InMemoryLogWriter
import io.music_assistant.client.platform.PlatformContext
import io.music_assistant.client.player.local.AudioQueueSink
import io.music_assistant.client.player.local.IosDecoderFactory
import io.music_assistant.client.settings.provideSettings
import kotlinx.cinterop.staticCFunction
import platform.Foundation.NSBundle
import platform.Foundation.NSException
import platform.Foundation.NSFileManager
import platform.Foundation.NSString
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.create
import platform.Foundation.writeToFile
import kotlin.native.Platform

/**
 * Builds the Kotlin object graph. Called once from Swift `iOSApp.init()`, before anything
 * reaches `KmpHelper`; idempotent anyway, because a single entry point that tolerates a
 * second call is easier to keep correct than a rule about call counts.
 */
fun bootstrapKmp() {
    kmpBootstrap
}

private val kmpBootstrap: Unit by lazy {
    AppGraph.start(
        graph = {
            AppGraph(
                settingsStore = provideSettings(),
                platformContext = PlatformContext(),
                // The Ktor WebRTC engine loads the WebRTC framework; only a remote connection needs it.
                webRtcClient = lazy { WebRtcClient(IosWebRtc) {} },
                // The native player (`NativeAudioController`) registers with
                // PlatformPlayerProvider; the sink resolves it on every stream open.
                localPlayerPorts = LocalPlayerPorts(
                    sink = { onRemoteCommand -> AudioQueueSink(onRemoteCommand) },
                    decoders = IosDecoderFactory(),
                    softwareVersion = appVersion(),
                ),
            )
        },
        verboseLogging = Platform.isDebugBinary,
    )
    cleanupStaleLogFile()
    installCrashHandler()
}

/** The marketing version ("1.4.2") reported to the Sendspin server in the player's hello. */
private fun appVersion(): String =
    NSBundle.mainBundle.objectForInfoDictionaryKey("CFBundleShortVersionString") as? String ?: "unknown"

private fun cleanupStaleLogFile() {
    NSFileManager.defaultManager.removeItemAtPath(
        "${NSTemporaryDirectory()}ma_client_logs.txt",
        error = null,
    )
}

private fun installCrashHandler() {
    platform.Foundation.NSSetUncaughtExceptionHandler(
        staticCFunction { exception: NSException? ->
            val path = "${NSTemporaryDirectory()}ma_crash_log.txt"
            NSFileManager.defaultManager.removeItemAtPath(path, error = null)
            val text = InMemoryLogWriter.getLogText() +
                "\n\n=== CRASH ===\n" + (exception?.description ?: "Unknown exception")
            val nsString = NSString.create(string = text)
            nsString.writeToFile(path, atomically = true, encoding = NSUTF8StringEncoding, error = null)
            Unit
        },
    )
}
