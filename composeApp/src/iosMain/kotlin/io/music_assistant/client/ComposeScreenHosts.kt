@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package io.music_assistant.client

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.ComposeUIViewController
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import io.music_assistant.client.api.DeepLinkBus
import io.music_assistant.client.api.DeepLinkDestination
import io.music_assistant.client.api.ErrorMessageBus
import io.music_assistant.client.data.model.client.MediaType
import io.music_assistant.client.di.KmpHelper
import io.music_assistant.client.input.VolumeButtonService
import io.music_assistant.client.ui.compose.AppLifecycleObserver
import io.music_assistant.client.ui.compose.common.ToastDuration
import io.music_assistant.client.ui.compose.common.ToastHost
import io.music_assistant.client.ui.compose.common.dismissKeyboardOnTap
import io.music_assistant.client.ui.compose.common.items.ProvideClickActionPrefs
import io.music_assistant.client.ui.compose.common.rememberToastState
import io.music_assistant.client.ui.compose.common.viewmodel.ActionsViewModel
import io.music_assistant.client.ui.compose.home.FloatingBar
import io.music_assistant.client.ui.compose.home.HomeScreenViewModel
import io.music_assistant.client.ui.compose.home.players.DspSettingsViewModel
import io.music_assistant.client.ui.compose.home.players.PlayersPager
import io.music_assistant.client.ui.compose.home.selectedPlayer
import io.music_assistant.client.ui.compose.nav.exitApp
import io.music_assistant.client.ui.compose.settings.SettingsScreen
import io.music_assistant.client.ui.theme.AppTheme
import io.music_assistant.client.ui.theme.SystemAppearance
import io.music_assistant.client.ui.theme.ThemeSetting
import io.music_assistant.client.ui.theme.ThemeViewModel
import io.music_assistant.client.ui.theme.isSystemInDarkTheme
import musicassistantclient.composeapp.generated.resources.Res
import musicassistantclient.composeapp.generated.resources.players_remote_volume_hint
import org.jetbrains.compose.resources.stringResource
import org.koin.compose.koinInject
import org.koin.compose.viewmodel.koinViewModel
import platform.UIKit.UIViewController

/**
 * Per-tab Compose hosts — one `UIViewController` factory per native `TabView` tab, plus the
 * floating player bar's own two hosts. Supersedes the single `MainAppController()` this file
 * used to export, which hosted all four tabs, `MultiBackStack`, and the floating bar as one
 * Compose tree wrapped by one Swift `NavigationStack` (`MainTabHostView.swift`, now
 * `AppTabView.swift`). That worked for Phase E1/E2 because every native push (ItemDetails,
 * the Library category grid, Browse) was a genuine drill-down *from inside* an already-showing
 * screen. Search doesn't fit that shape — it's a tab *root*, and pushing it the same way would
 * cover the tab bar along with everything else, since the tab bar was part of the same Compose
 * subtree being pushed over. Phase E3 (see `SearchView.swift`) needed real per-tab navigation,
 * so `AppTabView.swift` now owns tab switching and each tab's own `NavigationStack` — this file
 * stopped composing them all together.
 *
 * Home and Library both lost their Compose hosts entirely now (`HomeAppController`/
 * `LibraryAppController` are gone, along with the `ScreenState`/`rememberPublishedScreenState`
 * machinery that let the old shared nav bar scroll the active tab to top on re-tap — nothing in
 * `TabView` reproduces that trigger for free, so it's gone until someone rebuilds it, not
 * silently preserved). Neither screen's Kotlin ViewModel needed wrapping to get there:
 * `HomeScreenViewModel`'s complexity turned out to be about *when* to show loading/reconnecting
 * states, not about producing the row data itself, so `HomeView.swift` fetches
 * recommendations/shortcuts as one-shot round trips (`KmpHelper.fetchRecommendationFolders`/
 * `fetchShortcuts`) rather than wrapping the ViewModel's session state machine —
 * `LibraryCategoriesViewModel` was thinner still, a pass-through over
 * `SettingsRepository.libraryCategoryConfig`, so `LibraryView.swift` reads/writes that directly
 * via `KmpHelper.libraryCategoryConfig`/`setLibraryCategoryConfig`. See each Swift file's own
 * doc for the full reasoning.
 *
 * The floating player bar (`PlayersPager`/`FloatingBar`) is the one thing that was never a
 * "screen" reachable by push/pop — it's an always-on overlay spanning every tab, so it can't
 * just become a per-tab host. Splitting it into `FloatingBarCollapsedController` (mounted once
 * per tab, via each tab's own `.safeAreaInset` — see `AppTabView.swift`'s doc for why per-tab
 * rather than shared) and `FloatingBarExpandedController` (one shared instance, mounted only
 * while `.fullScreenCover` presents it) avoids the harder problem a single always-full-screen
 * overlay host would have — Compose UIViewControllers don't pass touches through to whatever's
 * underneath empty space, so a full-screen collapsed host would swallow taps on the tab bar and
 * every tab's content. Two ordinary SwiftUI presentations (a small fixed-height inset per tab, a
 * real full-screen cover) sidestep that entirely, at the cost of the expanded page's
 * queue-expanded/dialog-open state resetting on each expand — an accepted, minor loss; the
 * actually-important state (which player is selected, the queue itself) lives in the
 * `MainDataSource` singleton underneath every host, not in any one's local `remember`, so it
 * survives every mount/unmount any of them does. `ErrorMessageBus` (single-consumer by
 * construction — a `Channel`, not a broadcast `SharedFlow`) and the volume-button
 * remote-playback hint toast both live in `FloatingBarCollapsedController`, which — now that
 * it's per-tab — means an error toast surfaces on whichever tab's instance happens to receive
 * it, not necessarily the one on screen (documented, accepted tradeoff — see `AppTabView.swift`).
 */
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

/**
 * The always-mounted, purely side-effecting companion to the native `MiniPlayerView` —
 * pinned invisibly behind it at the bottom of every tab via `AppTabView.swift`'s
 * `.overlay`/`allowsHitTesting(false)`. Owns everything that must have exactly one live
 * instance for the app's lifetime but isn't itself UI: `ErrorMessageBus` → toast display,
 * the volume-button remote-playback hint toast, and consuming `DeepLinkDestination.Players`
 * to trigger expand. The collapsed player bar's own UI (`PlayersPager`/`FloatingBar`) moved
 * to native SwiftUI (`MiniPlayerView.swift`) — this controller no longer renders it, and
 * dropped the `onNavigateToItemDetails` param that only `ExpandedPlayerPage` ever used.
 */
@Suppress(
    "FunctionNaming",
) // iOS factory function intentionally PascalCase; called from Swift as if it were a constructor
fun FloatingBarSideEffectsController(
    onExpand: () -> Unit,
): UIViewController = ComposeUIViewController(
    configure = { bootstrapKmp() },
) {
    AppShellChrome {
        val toastState = rememberToastState()
        val errorBus = koinInject<ErrorMessageBus>()
        val deepLinkBus = koinInject<DeepLinkBus>()
        val volumeButtonService = koinInject<VolumeButtonService>()
        val homeScreenViewModel = koinViewModel<HomeScreenViewModel>()

        LaunchedEffect(Unit) {
            errorBus.messages.collect { msg ->
                val truncated = if (msg.length > MAX_TOAST_MESSAGE_LENGTH) msg.take(MAX_TOAST_MESSAGE_LENGTH) + "…" else msg
                toastState.showToast(truncated, ToastDuration.LONG)
            }
        }

        val playersState by homeScreenViewModel.playersState.collectAsStateWithLifecycle()
        val remoteVolumeHint = stringResource(Res.string.players_remote_volume_hint)
        val viewingRemote = (playersState as? HomeScreenViewModel.PlayersState.Data)?.selectedPlayer?.isLocal == false
        val currentHint by rememberUpdatedState(remoteVolumeHint)
        val observingRemote by rememberUpdatedState(viewingRemote)
        val lifecycleOwner = LocalLifecycleOwner.current
        LaunchedEffect(lifecycleOwner, volumeButtonService) {
            lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
                volumeButtonService.buttonPresses.collect {
                    if (observingRemote) {
                        toastState.showToast(currentHint, ToastDuration.SHORT)
                    }
                }
            }
        }

        val pendingDeepLink by deepLinkBus.pending.collectAsStateWithLifecycle()
        LaunchedEffect(pendingDeepLink) {
            val dest = pendingDeepLink
            if (dest is DeepLinkDestination.Players) {
                onExpand()
                deepLinkBus.consume(dest)
            }
        }

        Box(Modifier.fillMaxSize()) {
            ToastHost(toastState = toastState)
        }
    }
}

/** Mounted only while `.fullScreenCover` presents it — see this file's doc. */
@Suppress(
    "FunctionNaming",
) // iOS factory function intentionally PascalCase; called from Swift as if it were a constructor
fun FloatingBarExpandedController(
    onCollapse: () -> Unit,
    onNavigateToItemDetails: (itemId: String, mediaType: MediaType, providerId: String) -> Unit,
): UIViewController = ComposeUIViewController(
    configure = { bootstrapKmp() },
) {
    AppShellChrome {
        val homeScreenViewModel = koinViewModel<HomeScreenViewModel>()
        val playersState by homeScreenViewModel.playersState.collectAsStateWithLifecycle()
        PlayerBarContent(
            expanded = true,
            onExpandedChange = { if (!it) onCollapse() },
            onClose = onCollapse,
            homeScreenViewModel = homeScreenViewModel,
            playersState = playersState,
            onNavigateToItemDetails = onNavigateToItemDetails,
        )
    }
}

/**
 * Shared by both floating-bar hosts: a fresh [PagerState] per mount (re-derived from the
 * current [HomeScreenViewModel.PlayersState.Data.selectedPlayerIndex], not carried over from a
 * prior mount — see this file's doc on what's an accepted loss), the bidirectional pager<->
 * selection sync `MainNavRoot.kt` used to run at the top level, and the `FloatingBar` chrome
 * wrapping `PlayersPager`.
 */
@Composable
private fun PlayerBarContent(
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onClose: () -> Unit,
    homeScreenViewModel: HomeScreenViewModel,
    playersState: HomeScreenViewModel.PlayersState,
    onNavigateToItemDetails: (itemId: String, mediaType: MediaType, providerId: String) -> Unit,
) {
    val actionsViewModel = koinViewModel<ActionsViewModel>()
    val dspSettingsViewModel = koinViewModel<DspSettingsViewModel>()

    val data = playersState as? HomeScreenViewModel.PlayersState.Data
    val playerPagerState = rememberPagerState(
        initialPage = data?.selectedPlayerIndex ?: 0,
        pageCount = { data?.playerData?.size ?: 0 },
    )
    LaunchedEffect(playerPagerState, playersState) {
        val currentData = playersState as? HomeScreenViewModel.PlayersState.Data ?: return@LaunchedEffect
        val target = currentData.selectedPlayerIndex ?: return@LaunchedEffect
        if (!playerPagerState.isScrollInProgress) {
            playerPagerState.animateScrollToPage(target)
        }
        snapshotFlow { playerPagerState.settledPage }.collect { currentPage ->
            currentData.playerData.getOrNull(currentPage)?.let { playerData ->
                homeScreenViewModel.selectPlayer(playerData.player)
            }
        }
    }

    FloatingBar(expanded = expanded, onExpand = onExpandedChange) { isExpanded, contentPadding ->
        PlayersPager(
            playerPagerState = playerPagerState,
            state = playersState,
            homeScreenViewModel = homeScreenViewModel,
            actionsViewModel = actionsViewModel,
            dspSettingsViewModel = dspSettingsViewModel,
            expanded = isExpanded,
            onClose = onClose,
            contentPadding = contentPadding,
        ) { item -> onNavigateToItemDetails(item.itemId, item.mediaType, item.provider) }
    }
}

private const val MAX_TOAST_MESSAGE_LENGTH = 150

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
