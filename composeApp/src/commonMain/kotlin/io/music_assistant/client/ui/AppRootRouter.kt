package io.music_assistant.client.ui

import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.auth.AuthenticationManager
import io.music_assistant.client.utils.AuthProcessState
import io.music_assistant.client.utils.DataConnectionState
import io.music_assistant.client.utils.SessionState
import io.music_assistant.client.utils.mainDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Which top-level surface is showing: the authenticated tab shell, or connection setup. */
enum class AppRootDestination { MAIN, SETTINGS }

/** Mirrors the reconnection-banner states the deleted Compose `ConnectionStatusBanner` used to render. */
sealed interface AppBannerState {
    data class Reconnecting(val attempt: Int) : AppBannerState
    data object NoNetwork : AppBannerState
}

/**
 * Single source of truth for "what does the top level of the app look like right
 * now" — which screen (Main tab shell vs. Settings), whether the cold-launch
 * auto-login splash is up, and whether a reconnection banner should show.
 *
 * This is a straight extraction of the policy that used to live entirely inside
 * the Compose `TopLevelNavRoot` Composable's `LaunchedEffect`s: which screen to
 * force on a session-state transition, and when the splash latches closed for
 * good. It moved here — as a plain reactive class, constructor-injected and
 * Koin-eager — for two reasons: it is exactly the kind of behavioural policy the
 * migration plan says must stay identical across every UI that drives it, and
 * unlike a `remember { mutableStateOf(...) }` trapped inside a Composable, it
 * can now be unit tested and it survives independently of whatever is currently
 * observing it (a SwiftUI view redrawing, or nothing at all).
 *
 * `TopLevelNavRoot.kt` (and the `ConnectionStatusBanner.kt`/`AutoLoginSplash.kt`
 * Composables it drove) is gone now — this class fully superseded it, and with
 * Android also gone from this fork, nothing else rendered them. The SwiftUI
 * shell (`AppRouter` in `iosApp/Shell/AppRouter.swift`) is the sole consumer,
 * via the `NativeStateFlow`s exposed on the bridge (`KmpHelper.kt`).
 */
class AppRootRouter(
    private val serviceClient: ServiceClient,
    private val authManager: AuthenticationManager,
) {
    private val scope = CoroutineScope(SupervisorJob() + mainDispatcher)

    // Latches closed the first time the splash resolves (success or failure) so
    // a later user-initiated reconnect — which revisits Connecting/Initial-shaped
    // states — never brings it back. Deliberately not part of the destination/
    // splash StateFlows: it's process state, not something either UI projects.
    private var splashDismissedLatch = false

    private val _destination = MutableStateFlow(computeInitialDestination())
    val destination: StateFlow<AppRootDestination> = _destination.asStateFlow()

    private val _splashVisible = MutableStateFlow(false)
    val splashVisible: StateFlow<Boolean> = _splashVisible.asStateFlow()

    private val _bannerState = MutableStateFlow<AppBannerState?>(null)
    val bannerState: StateFlow<AppBannerState?> = _bannerState.asStateFlow()

    init {
        // Compute synchronously from the current value so a subscriber reading
        // .value immediately after construction (before the collector below gets
        // its first turn on the run loop) never sees a placeholder.
        onSessionState(serviceClient.sessionState.value)
        scope.launch {
            serviceClient.sessionState.collect(::onSessionState)
        }
    }

    /** Cancels the in-flight auto-login attempt and permanently dismisses the splash. */
    fun cancelAutoLogin() {
        serviceClient.disconnectByUser()
        splashDismissedLatch = true
        _splashVisible.value = false
    }

    /**
     * User-initiated navigation to Settings (tapping the Settings tab), independent
     * of [sessionState] — unlike [updateDestination]'s rules, this fires regardless
     * of connection state, mirroring the unconditional `backStack.add(Nav.Settings)`
     * this replaced.
     */
    fun requestSettings() {
        _destination.value = AppRootDestination.SETTINGS
    }

    /**
     * User-initiated return to the main shell (Settings' back button/gesture).
     * Callers are expected to only offer this while authenticated — same
     * precondition the Compose and SwiftUI Settings screens already enforce
     * before wiring it up, so it isn't re-checked here.
     */
    fun requestHome() {
        _destination.value = AppRootDestination.MAIN
    }

    private fun onSessionState(state: SessionState) {
        updateSplashVisibility(state)
        updateDestination(state)
        _bannerState.value = when {
            state is SessionState.Reconnecting && state.isOnline -> AppBannerState.Reconnecting(state.attempt)
            state is SessionState.Reconnecting -> AppBannerState.NoNetwork
            else -> null
        }
    }

    private fun computeInitialDestination(): AppRootDestination {
        val state = serviceClient.sessionState.value
        return when {
            state is SessionState.Connected && state.dataConnectionState is DataConnectionState.Authenticated ->
                AppRootDestination.MAIN

            authManager.willAutoLoginOnLaunch -> AppRootDestination.MAIN
            else -> AppRootDestination.SETTINGS
        }
    }

    private fun updateSplashVisibility(state: SessionState) {
        val visible = !splashDismissedLatch &&
            authManager.willAutoLoginOnLaunch &&
            when (state) {
                SessionState.Disconnected.Initial -> true
                SessionState.Connecting -> true
                is SessionState.Connected ->
                    state.dataConnectionState !is DataConnectionState.Authenticated &&
                        state.authProcessState !is AuthProcessState.Failed

                else -> false
            }
        _splashVisible.value = visible

        val terminal = when (state) {
            is SessionState.Connected ->
                state.dataConnectionState is DataConnectionState.Authenticated ||
                    state.authProcessState is AuthProcessState.Failed

            is SessionState.Disconnected.Error,
            is SessionState.Disconnected.ByUser,
            is SessionState.Disconnected.NoServerData,
                -> true

            else -> false
        }
        if (terminal) splashDismissedLatch = true
    }

    private fun updateDestination(state: SessionState) {
        val target = when (state) {
            is SessionState.Reconnecting -> null // preserve current screen
            is SessionState.Disconnected -> when (state) {
                // Backgrounded: preserve, for instant foreground reconnect. Initial: this is
                // the transient pre-connection moment, always followed by Connecting in real
                // usage — forcing Settings here would fight computeInitialDestination()'s bias
                // toward Main when a saved token means auto-login is about to run, for no
                // benefit (nothing has actually failed yet). ByUser/NoServerData/Error are
                // resolved outcomes the user should act on, so those do force Settings.
                is SessionState.Disconnected.Backgrounded,
                is SessionState.Disconnected.Initial,
                    -> null

                else -> AppRootDestination.SETTINGS
            }

            is SessionState.Connected -> when {
                state.dataConnectionState is DataConnectionState.Authenticated && state.wasAutoLogin ->
                    AppRootDestination.MAIN

                state.authProcessState is AuthProcessState.Failed -> AppRootDestination.SETTINGS

                // Connected, but no token to auto-login with (e.g. the server revoked it and
                // AuthenticationManager cleared it). AuthMgr logs "no saved token" and stops;
                // without this the user stays on Main with every request timing out.
                state.dataConnectionState is DataConnectionState.AwaitingAuth &&
                    state.authProcessState is AuthProcessState.NotStarted &&
                    !authManager.hasSavedTokenFor(state) -> AppRootDestination.SETTINGS

                else -> null // other Connected sub-states don't force a screen
            }

            is SessionState.Connecting -> null
        } ?: return
        if (_destination.value != target) _destination.value = target
    }
}
