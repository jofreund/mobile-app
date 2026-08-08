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
import io.music_assistant.client.data.model.client.MediaType
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
 * Per-screen Compose hosts, replacing the single Compose entry point
 * `ContentView.swift` used to boot (the old `MainViewController()` /
 * `App()` / `TopLevelNavRoot.kt` chain — all now deleted, fully superseded).
 * `AppRouter.swift` now owns that switch (Main tab shell vs. Settings) by
 * reading [KmpHelper.rootDestination] — these two factories are what it
 * mounts for each side, so this file only reproduces the shared Compose
 * *chrome* `App()` used to apply (theme, click-action prefs, keyboard
 * dismissal, foreground/background lifecycle via [AppLifecycleObserver]),
 * not the switch itself.
 *
 * Deliberately scoped narrower than the full per-screen breakdown the
 * migration plan describes for this phase: [MainNavigationRoot] still owns
 * its internal tab/push navigation (`MultiBackStack`) *and* the persistent
 * floating player bar (`PlayersPager`/`FloatingBar`) exactly as it does
 * today, for every destination *except* `ItemDetails`. Replacing the rest
 * with native `TabView`/`NavigationPath` is real, substantial work of its
 * own — the floating bar in particular isn't a "screen" reachable by
 * push/pop, it's an always-on overlay, so it needs its own hosted-overlay
 * design before it can be pulled out. Doing that alongside an untested
 * rewrite of every remaining push destination (`Browse`, `LibraryList`,
 * `ItemList`, …) in one pass would risk shipping a build that silently
 * drops player controls.
 *
 * `ItemDetails` was the first step into Phase E1, and the Library tab's own
 * category grid (Artists/Albums/…) plus the Browse tree followed the same
 * pattern for Phase E2: every place [MainNavigationRoot] used to push its own
 * internal `MainNav.ItemDetails` / `MainNav.LibraryList` / `MainNav.Browse`
 * (Home rows, Library, Browse, Search, and the floating bar's own queue-item
 * tap) now calls [onNavigateToItemDetails] / [onNavigateToLibraryCategory] /
 * [onNavigateToBrowse] instead — plain Kotlin closures Swift passes in
 * directly, no NativeStateFlow needed since these are one-shot calls, not an
 * observed stream. `AppShellRootView`'s Main case wraps this controller in a
 * real `NavigationStack` and pushes a native screen when any of them fires.
 * `ItemList`'s own search/sort/filter is still Compose-owned — replacing the
 * rest of the Library tab alongside an untested rewrite of every remaining
 * push destination in one pass would risk shipping a build that silently
 * drops player controls.
 */
@Suppress(
    "FunctionNaming",
) // iOS factory function intentionally PascalCase; called from Swift as if it were a constructor
fun MainAppController(
    onNavigateToItemDetails: (itemId: String, mediaType: MediaType, providerId: String) -> Unit,
    onNavigateToLibraryCategory: (mediaType: MediaType) -> Unit,
    onNavigateToBrowse: () -> Unit,
): UIViewController = ComposeUIViewController(
    configure = { bootstrapKmp() },
) {
    AppShellChrome {
        MainNavigationRoot(
            goToSettings = { KmpHelper.requestSettings() },
            onNavigateToItemDetails = onNavigateToItemDetails,
            onNavigateToLibraryCategory = onNavigateToLibraryCategory,
            onNavigateToBrowse = onNavigateToBrowse,
        )
    }
}

@Suppress(
    "FunctionNaming",
) // iOS factory function intentionally PascalCase; called from Swift as if it were a constructor
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
