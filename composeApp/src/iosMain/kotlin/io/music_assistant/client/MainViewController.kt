@file:OptIn(
    kotlinx.cinterop.ExperimentalForeignApi::class,
    kotlinx.cinterop.BetaInteropApi::class,
    kotlin.experimental.ExperimentalNativeApi::class,
)

package io.music_assistant.client

import io.music_assistant.client.di.initKoin
import io.music_assistant.client.di.iosModule
import io.music_assistant.client.logging.InMemoryLogWriter
import kotlinx.cinterop.staticCFunction
import platform.Foundation.NSException
import platform.Foundation.NSFileManager
import platform.Foundation.NSString
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.create
import platform.Foundation.writeToFile
import kotlin.native.Platform

/**
 * Idempotent KMP/Koin initialization. Called from two places:
 *
 *   1. Swift `iOSApp.init()` — runs before any scene connects, so a
 *      CarPlay-only cold launch (head unit tap, no SwiftUI scene) still
 *      gets Koin set up.
 *   2. Each `ComposeUIViewController` factory in `ComposeScreenHosts.kt`
 *      (`configure = { bootstrapKmp() }`) — runs when its host is first
 *      mounted, which on a SwiftUI-only cold launch happens before the
 *      CarPlay scene exists.
 *
 * Idempotency is mandatory because both paths can run on a single launch
 * (CarPlay scene + SwiftUI scene both connecting). Backed by `Unit by lazy`
 * — `startKoin` throws on a second invocation otherwise.
 */
fun bootstrapKmp() {
    kmpBootstrap
}

private val kmpBootstrap: Unit by lazy {
    initKoin(iosModule(), verboseLogging = Platform.isDebugBinary)
    cleanupStaleLogFile()
    installCrashHandler()
}

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
