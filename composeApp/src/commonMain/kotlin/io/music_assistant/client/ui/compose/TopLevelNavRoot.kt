package io.music_assistant.client.ui.compose

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.music_assistant.client.ui.AppRootDestination
import io.music_assistant.client.ui.AppRootRouter
import io.music_assistant.client.ui.compose.common.AutoLoginSplash
import io.music_assistant.client.ui.compose.common.ConnectionStatusBanner
import io.music_assistant.client.ui.compose.home.MainNavigationRoot
import io.music_assistant.client.ui.compose.nav.exitApp
import io.music_assistant.client.ui.compose.settings.SettingsScreen
import org.koin.compose.koinInject

/**
 * Switches between the authenticated tab shell ([MainNavigationRoot]) and
 * connection setup ([SettingsScreen]), plus the cold-launch splash and
 * reconnection banner overlays.
 *
 * All of that switching policy — which screen a given `sessionState`
 * transition should force, and when the splash latches closed for good —
 * lives in [AppRootRouter], not here. This function just renders whatever it
 * says. See [AppRootRouter]'s doc for why: iOS drives the identical decision
 * natively (`AppRouter.swift`) from the same singleton, so nothing here is a
 * one-off — duplicating it locally would be exactly the kind of drift the
 * shared-core boundary exists to prevent.
 */
@Composable
fun TopLevelNavRoot(modifier: Modifier = Modifier) {
    val router: AppRootRouter = koinInject()
    val destination by router.destination.collectAsStateWithLifecycle()
    val splashVisible by router.splashVisible.collectAsStateWithLifecycle()

    Box(modifier = modifier) {
        when (destination) {
            AppRootDestination.MAIN -> MainNavigationRoot(
                goToSettings = router::requestSettings,
            )

            AppRootDestination.SETTINGS -> SettingsScreen(
                goHome = router::requestHome,
                exitApp = { exitApp() },
            )
        }

        ConnectionStatusBanner(
            modifier = Modifier.align(Alignment.TopCenter),
        )

        // Auto-login splash — drawn last so it covers the banner during the splash window.
        AutoLoginSplash(
            visible = splashVisible,
            onCancel = router::cancelAutoLogin,
            modifier = Modifier.fillMaxSize(),
        )
    }
}
