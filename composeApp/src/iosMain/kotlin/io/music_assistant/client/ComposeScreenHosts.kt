@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package io.music_assistant.client

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.ComposeUIViewController
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.music_assistant.client.di.KmpHelper
import io.music_assistant.client.ui.compose.AppLifecycleObserver
import io.music_assistant.client.ui.compose.common.dismissKeyboardOnTap
import io.music_assistant.client.ui.compose.common.items.ProvideClickActionPrefs
import io.music_assistant.client.ui.compose.home.MainNavigationRoot
import io.music_assistant.client.ui.compose.nav.exitApp
import io.music_assistant.client.ui.compose.settings.SettingsScreen
import io.music_assistant.client.ui.theme.AppTheme
import io.music_assistant.client.ui.theme.SystemAppearance
import io.music_assistant.client.ui.theme.ThemeSetting
import io.music_assistant.client.ui.theme.ThemeViewModel
import io.music_assistant.client.ui.theme.isSystemInDarkTheme
import org.koin.compose.viewmodel.koinViewModel
import platform.UIKit.UIViewController

/**
 * Per-screen Compose hosts, replacing the single [MainViewController] entry
 * point `ContentView.swift` used to boot. `AppRouter.swift` now owns the
 * decision `TopLevelNavRoot.kt` used to make (Main tab shell vs. Settings) by
 * reading [KmpHelper.rootDestination] — these two factories are what it
 * mounts for each side of that switch, so this file only reproduces the
 * shared Compose *chrome* [App] used to apply (theme, click-action prefs,
 * keyboard dismissal, foreground/background lifecycle), not the switch
 * itself.
 *
 * Deliberately scoped narrower than the full per-screen breakdown the
 * migration plan describes for this phase: [MainNavigationRoot] still owns
 * its internal tab/push navigation (`MultiBackStack`) *and* the persistent
 * floating player bar (`PlayersPager`/`FloatingBar`) exactly as it does
 * today. Replacing those with native `TabView`/`NavigationPath` is real,
 * substantial work of its own — the floating bar in particular isn't a
 * "screen" reachable by push/pop, it's an always-on overlay, so it needs its
 * own hosted-overlay design before it can be pulled out. Doing that alongside
 * an untested rewrite of every push destination (`ItemDetails`, `Browse`,
 * `LibraryList`, `ItemList`, …) in one pass would risk shipping a build that
 * silently drops player controls. This slice proves the Swift↔Kotlin router
 * bridge end to end without touching any of that.
 *
 * Known gap: `SchemaVersionWarningDialog` (schema-mismatch warning) lived in
 * `App()` and isn't reproduced here yet — narrow (only fires against an
 * incompatible server) but real; worth folding into `AppRootRouter` the same
 * way the splash/banner were, in a follow-up.
 */
fun MainAppController(): UIViewController = ComposeUIViewController(
    configure = { bootstrapKmp() },
) {
    AppShellChrome {
        MainNavigationRoot(goToSettings = { KmpHelper.requestSettings() })
    }
}

fun SettingsAppController(): UIViewController = ComposeUIViewController(
    configure = { bootstrapKmp() },
) {
    AppShellChrome {
        SettingsScreen(
            goHome = { KmpHelper.requestHome() },
            exitApp = { exitApp() },
        )
    }
}

/** The cross-cutting wrapping [io.music_assistant.client.ui.compose.App] applied, minus its own
 * Main/Settings switch — see this file's doc for what's deliberately not reproduced. */
@Composable
private fun AppShellChrome(content: @Composable () -> Unit) {
    AppLifecycleObserver()
    val themeViewModel = koinViewModel<ThemeViewModel>()
    val theme = themeViewModel.theme.collectAsStateWithLifecycle(ThemeSetting.FollowSystem)
    val followsSystem = theme.value == ThemeSetting.FollowSystem
    val darkTheme = when (theme.value) {
        ThemeSetting.Dark -> true
        ThemeSetting.Light -> false
        ThemeSetting.FollowSystem -> isSystemInDarkTheme()
    }
    SystemAppearance(isDarkTheme = darkTheme, followsSystem = followsSystem)
    AppTheme(darkTheme = darkTheme) {
        Box(
            Modifier.fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .dismissKeyboardOnTap(),
        ) {
            ProvideClickActionPrefs { content() }
        }
    }
}
