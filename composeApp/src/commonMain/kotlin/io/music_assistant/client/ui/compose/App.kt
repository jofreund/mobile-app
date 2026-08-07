package io.music_assistant.client.ui.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.music_assistant.client.api.ServiceClient
import org.koin.compose.koinInject

/**
 * Reports Compose's own lifecycle owner transitions as app foreground/background
 * to [ServiceClient]. Used directly by `ComposeScreenHosts.kt`'s per-host wrapper
 * (iosMain) — kept public and standalone for that; it used to be a private detail
 * of `App()`, which owned the whole Compose tree before the SwiftUI shell
 * (`AppShellRootView.swift`) took over the Main/Settings switch, splash, banner,
 * and schema-warning dialog `App()` used to render (see `AppRootRouter`'s doc).
 */
@Composable
fun AppLifecycleObserver() {
    val serviceClient: ServiceClient = koinInject()
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> serviceClient.onAppForeground()
                Lifecycle.Event.ON_STOP -> serviceClient.onAppBackground()
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }
}
