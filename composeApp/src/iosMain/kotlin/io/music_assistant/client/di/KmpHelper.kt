@file:OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)

package io.music_assistant.client.di

import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.readRawBytes
import io.ktor.http.Url
import io.music_assistant.client.api.APICommands
import io.music_assistant.client.api.ConnectionInfo
import io.music_assistant.client.api.ErrorMessageBus
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.api.isAccepted
import io.music_assistant.client.auth.AuthState
import io.music_assistant.client.auth.AuthenticationManager
import io.music_assistant.client.bridge.Cancellable
import io.music_assistant.client.bridge.NativeFlow
import io.music_assistant.client.bridge.NativeStateFlow
import io.music_assistant.client.bridge.NativeSuspend
import io.music_assistant.client.data.ChapterBarItem
import io.music_assistant.client.data.LiveActivitySnapshot
import io.music_assistant.client.data.MainDataSource
import io.music_assistant.client.data.NowPlayingModes
import io.music_assistant.client.data.NowPlayingTrack
import io.music_assistant.client.data.NowPlayingTransport
import io.music_assistant.client.data.PlayerBarState
import io.music_assistant.client.data.model.client.LibraryFilters
import io.music_assistant.client.data.model.client.MediaType
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.QueueOption
import io.music_assistant.client.data.model.client.SortConfig
import io.music_assistant.client.data.model.client.SortOption
import io.music_assistant.client.data.model.client.SubItemContext
import io.music_assistant.client.data.model.client.chapterSeekSeconds
import io.music_assistant.client.data.model.client.clientSorted
import io.music_assistant.client.data.model.client.items.Album
import io.music_assistant.client.data.model.client.items.AppMediaItem
import io.music_assistant.client.data.model.client.items.Artist
import io.music_assistant.client.data.model.client.items.Audiobook
import io.music_assistant.client.data.model.client.items.Genre
import io.music_assistant.client.data.model.client.items.MarkableItem
import io.music_assistant.client.data.model.client.items.Playlist
import io.music_assistant.client.data.model.client.items.Podcast
import io.music_assistant.client.data.model.client.items.PodcastEpisode
import io.music_assistant.client.data.model.client.items.RadioStation
import io.music_assistant.client.data.model.client.items.RecommendationFolder
import io.music_assistant.client.data.model.client.items.Track
import io.music_assistant.client.data.model.server.AuthProvider
import io.music_assistant.client.data.model.server.ServerProviderInstance
import io.music_assistant.client.data.model.server.ServerUser
import io.music_assistant.client.data.model.server.supportsSleepTimer
import io.music_assistant.client.data.repository.MediaItemChange
import io.music_assistant.client.data.repository.MediaItemRepository
import io.music_assistant.client.data.repository.SearchResultData
import io.music_assistant.client.logging.InMemoryLogWriter
import io.music_assistant.client.logging.LogSharer
import io.music_assistant.client.player.sendspin.SendspinState
import io.music_assistant.client.settings.ConnectionHistoryEntry
import io.music_assistant.client.settings.SettingsRepository
import io.music_assistant.client.ui.compose.common.DataState
import io.music_assistant.client.ui.compose.common.action.PlayerAction
import io.music_assistant.client.ui.compose.common.action.QueueAction
import io.music_assistant.client.ui.compose.common.viewmodel.createPlaylistAwaitingConfirmation
import io.music_assistant.client.ui.compose.item.ItemUseCases
import io.music_assistant.client.utils.HasConnectionData
import io.music_assistant.client.utils.SessionState
import io.music_assistant.client.utils.currentTimeMillis
import io.music_assistant.client.utils.resultAs
import io.music_assistant.client.webrtc.model.RemoteId
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import platform.Foundation.NSData
import platform.Foundation.create

private val log = Logger.withTag("KmpHelper")

/**
 * How long to wait for a reply before giving up on a fetch.
 *
 * This is a guard against a reply that never comes, **not** a latency budget. `sendRequestRaw`
 * has no timeout of its own — it registers an RPC callback and suspends until the response
 * arrives or the caller cancels — so without something here a lost reply would hang the caller
 * for the rest of the session. That is the only job this has.
 *
 * It was 5 seconds, and that number came from CarPlay (`2238b503`), where a drive-quality
 * requirement made failing fast the right trade for a short list. CarPlay is deleted, and the
 * budget it left behind was governing every fetch in a phone UI where the user is watching a
 * spinner and would far rather wait than be told the load failed. It was too tight to be
 * survivable: `music/recommendations` on a real library exceeded it on a first home load, so the
 * app's opening screen could greet you with an error for no reason other than the server taking
 * six seconds to think.
 *
 * 30s is chosen to be comfortably longer than any request the server plausibly answers slowly
 * (recommendations and all-albums-by-artist fan out across providers) while still bounded, so a
 * genuinely lost reply resolves rather than hanging forever.
 */
private const val FETCH_TIMEOUT_MS = 30_000L

/**
 * See [KmpHelper.systemTogglePlayPause]. Bounded by the intent-execution budget the system gives
 * a backgrounded app process (roughly ten seconds) — must fail soft before iOS kills the intent,
 * not race it. Comfortably covers a LAN direct connect; a slow WebRTC signaling round trip is the
 * case that times out, and the button simply does nothing then.
 */
private const val SYSTEM_COMMAND_TIMEOUT_MS = 8_000L

/** See [fetchTracks]. */
private const val TRACKS_FETCH_LIMIT = 500

/** See [fetchLibraryItems]. Matches LibraryListViewModel.PAGE_SIZE. */
private const val LIBRARY_PAGE_SIZE = 50

/** See [KmpHelper.searchDetailed]. Matches SearchViewModel.performSearch's own limit. */
private const val SEARCH_RESULT_LIMIT = 200

/** A provider entry for the library filter sheet's provider picker. See [KmpHelper.fetchLibraryProviderOptions]. */
data class LibraryProviderOption(val instanceId: String, val label: String)

/** A genre entry for the library filter sheet's genre picker. See [KmpHelper.fetchLibraryGenreOptions]. */
data class LibraryGenreOption(val genreId: Int, val label: String)

/**
 * A transient message for the native toast host. See [KmpHelper.toasts].
 *
 * [isLong] rather than a duration in milliseconds: the two call sites only ever picked between
 * Compose's `ToastDuration.SHORT`/`LONG`, and how long "long" is belongs to the presenter.
 */
data class ToastMessage(val text: String, val isLong: Boolean)

/**
 * Server error text can be arbitrarily long — a stack-trace-ish RPC error would otherwise fill
 * the screen. Carried over from the Compose toast host verbatim.
 */
private const val MAX_TOAST_MESSAGE_LENGTH = 150

private fun String.truncatedForToast(): String =
    if (length > MAX_TOAST_MESSAGE_LENGTH) take(MAX_TOAST_MESSAGE_LENGTH) + "…" else this

/**
 * KmpHelper - the one Kotlin object Swift calls; reads everything from [AppGraph.shared]
 */
object KmpHelper {
    private val graph: AppGraph get() = AppGraph.shared

    val mainDataSource: MainDataSource get() = graph.mainDataSource
    val serviceClient: ServiceClient get() = graph.serviceClient
    val authManager: AuthenticationManager get() = graph.authManager
    private val mediaItemRepository: MediaItemRepository get() = graph.mediaItemRepository
    private val settingsRepository: SettingsRepository get() = graph.settingsRepository
    private val errorBus: ErrorMessageBus get() = graph.errorBus
    private val logSharer: LogSharer get() = graph.logSharer
    private val artworkHttpClient: HttpClient get() = graph.webrtcHttpClient

    // Provide a scope for Swift to launch coroutines if needed
    val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // The app-root policy (Main vs. Settings, auto-login splash, reconnection banner) and the
    // schema-floor check live in Swift now — `AppRootPolicy.swift` / `AppRouter.swift` — fed by
    // [sessionState] below. Nothing else reads them, so nothing bridges them.

    // Deep links and the OAuth callback URL are parsed in Swift (`DeepLinks.swift`); nothing
    // about them crosses the bridge except the token or the failure reason.

    /**
     * The connected MA server's stable identifier (UUID-style, e.g.
     * "70e548..."). Available once the server has sent its handshake;
     * null while the connection is still being established.
     */
    fun getServerId(): String? {
        return (serviceClient.sessionState.value as? HasConnectionData)
            ?.connectionData
            ?.serverInfo
            ?.serverId
    }

    // MARK: - Transient messages (toasts)
    //
    // Both sources used to be collected inside `FloatingBarSideEffectsController`, the last
    // mounted Compose in the app, which existed largely to host them. Merging here keeps the
    // policy — what warrants a toast, and for how long — in Kotlin, and leaves Swift with
    // nothing to decide but how it looks (`ToastHost.swift`).

    /**
     * Everything the app wants to say in passing: RPC errors from the server, and the hint that
     * the hardware volume buttons don't reach a remote player.
     *
     * Built once rather than per access. [ErrorMessageBus] is a `Channel`, so its flow is
     * single-consumer by construction — a second subscriber would not duplicate messages, it
     * would *steal* them. One host subscribes. (The Compose version was mounted once per tab and
     * did exactly that, which is why an error could surface on a tab you weren't looking at.)
     *
     * The remote-volume check reads [MainDataSource.selectedPlayer] at press time instead of
     * tracking a `viewingRemote` flag, which is both simpler and closes the window where the
     * flag lagged the selection.
     */
    private val toastMessages: Flow<ToastMessage> by lazy {
        errorBus.messages.map { ToastMessage(it.truncatedForToast(), isLong = true) }
    }

    val toasts: NativeFlow<ToastMessage>
        get() = NativeFlow(toastMessages, mainScope)

    // MARK: - App lifecycle
    //
    // Replaces `App.kt`'s `AppLifecycleObserver`, which reported Compose's own LifecycleOwner
    // transitions. Swift drives these from `scenePhase` now — see `iOSApp.swift`.

    fun onAppForeground() = serviceClient.onAppForeground()
    fun onAppBackground() = serviceClient.onAppBackground()

    // MARK: - Artwork loader (Swift-callable)
    //
    // Swift CarPlay / MPNowPlayingInfoCenter previously fetched artwork through
    // `URLSession.shared.dataTask(...)`. That bypasses the WebRTC data-channel proxy
    // (URLSession can't speak `mawebrtc://`) and breaks lock-screen / CarPlay artwork
    // whenever the URL we hand Swift is a synthetic proxy URL. This helper routes:
    //   - `mawebrtc://...` → `WebRTCHttpProxy.get(...)` (returns hex-decoded bytes)
    //   - `http(s)://...`  → Ktor GET
    // Swift consumes the NSData and builds the UIImage.
    fun loadArtworkBytes(
        urlString: String,
        completion: (NSData?) -> Unit,
    ): Cancellable {
        val job = mainScope.launch {
            val bytes = try {
                fetchArtworkInternal(urlString)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                log.w { "loadArtworkBytes failed for $urlString: ${e.message}" }
                null
            }
            completion(bytes?.toNSData())
        }
        return Cancellable { job.cancel() }
    }

    private suspend fun fetchArtworkInternal(urlString: String): ByteArray? = when {
        urlString.startsWith("mawebrtc://") -> {
            val proxy = serviceClient.webRTCHttpProxy ?: return null
            val parsed = Url(urlString)
            val tail = parsed.encodedQuery.let { q ->
                if (q.isEmpty()) parsed.encodedPath else "${parsed.encodedPath}?$q"
            }
            val response = proxy.get(tail)
            response.body.takeIf { response.status in 200..299 }
        }
        urlString.startsWith("http://") || urlString.startsWith("https://") -> {
            val response = artworkHttpClient.get(urlString)
            response.readRawBytes().takeIf { response.status.value in 200..299 }
        }
        else -> null
    }

    private fun ByteArray.toNSData(): NSData {
        if (isEmpty()) return NSData()
        return usePinned { pinned ->
            NSData.create(bytes = pinned.addressOf(0), length = size.toULong())
        }
    }

    // MARK: - Readiness observation

    /**
     * Subscribe to transport command-readiness. Fires with the current value
     * on subscribe and on every change.
     */
    fun observeReadiness(onChanged: (Boolean) -> Unit): Cancellable {
        val job = mainScope.launch {
            serviceClient.isReadyForCommands.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    /**
     * Command-readiness right now, for a caller that needs to *judge* a result rather than watch
     * for changes.
     *
     * Exists because the fetchers above cannot say why a list is empty. `sendRequest` gates on
     * `ensureReadyForCommands` and returns a failed Result when the transport never came up, and
     * [launchFetch] flattens that to an empty list — so "server answered with nothing" and "we
     * never reached the server" arrive at Swift as the same value. Reading this at the moment a
     * fetch resolves is what tells them apart.
     */
    val readyForCommands: Boolean
        get() = serviceClient.isReadyForCommands.value

    // MARK: - Now Playing channels
    //
    // Per-concern state for the system media UI (lock screen / Control Center /
    // CarPlay). Each observer replays the current value on subscribe — late
    // subscribers (CarPlay connecting mid-playback, foreground return) catch up
    // immediately. Callbacks arrive on the main thread; Swift needs no dispatch
    // hop. `null` means "nothing to present" (no current track).

    // MARK: - Swift Helpers for Data Fetching
    //
    // Every fetcher returns a nullable list. `null` means the round trip
    // exceeded FETCH_TIMEOUT_MS — Swift renders a disconnected affordance. Note that an RPC
    // *error* does not reach that path: callers reduce a failed Result to an empty list, so a
    // null here means the reply never arrived, not that the server refused.
    // An empty list means the server answered with nothing.

    private inline fun <T> launchFetch(
        label: String,
        crossinline completion: (List<T>?) -> Unit,
        crossinline fetch: suspend () -> List<T>,
    ) {
        val startMs = currentTimeMillis()
        log.i { "fetch[$label] start" }
        mainScope.launch {
            val items: List<T>? = withTimeoutOrNull(FETCH_TIMEOUT_MS) { fetch() }
            val elapsed = currentTimeMillis() - startMs
            if (items == null) {
                log.i { "fetch[$label] timeout after ${elapsed}ms" }
            } else {
                log.i { "fetch[$label] returned ${items.size} items in ${elapsed}ms" }
            }
            completion(items)
        }
    }

    fun fetchRecommendations(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("recommendations", completion) {
            mediaItemRepository.fetchRecommendationFolders().getOrNull()
                ?: emptyList()
        }
    }

    fun fetchRecommendationFolders(
        completion: (List<RecommendationFolder>?) -> Unit,
    ) {
        launchFetch("recommendationFolders", completion) {
            mediaItemRepository.fetchRecommendationFolders().getOrNull()
                ?: emptyList()
        }
    }

    /**
     * The native Home tab's "shortcuts" row — mirrors `HomeScreenViewModel.loadData`'s
     * resolution exactly: read the signed-in user's `sidebar.shortcuts` URI list, then fetch
     * each URI's item individually. A URI that no longer resolves is silently dropped
     * (`mapNotNull`), same as the Compose original.
     */
    fun fetchShortcuts(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("shortcuts", completion) {
            val shortcutUris = serviceClient.sendRequest(Request(APICommands.AUTH_ME))
                .resultAs<ServerUser>()?.preferences?.shortcuts
            shortcutUris?.mapNotNull {
                mediaItemRepository.fetchMediaItem(
                    Request(
                        command = APICommands.MUSIC_ITEM_BY_URI,
                        args = buildJsonObject { put("uri", JsonPrimitive(it)) },
                    ),
                ).getOrNull()
            } ?: emptyList()
        }
    }

    // MARK: - Settings (native Settings screen — connection setup, login/OAuth, and the
    // connected+authenticated sections; Car actions/DSP settings still stay Compose-only,
    // see SettingsView.swift's doc)

    /**
     * Live session state, exposed as-is (a real Kotlin sealed class, `is`/`as?`-matchable from
     * Swift — same pattern `DeepLinkDestination` already uses) rather than flattened, so
     * `SettingsView.swift` can decide per-emission whether to render natively (`Connected` +
     * `Authenticated`) or fall back to hosting the unmodified Compose `SettingsScreen` for every
     * other state (connecting, reconnecting, disconnected, mid-auth).
     */
    val sessionState: NativeStateFlow<SessionState> get() = NativeStateFlow(serviceClient.sessionState, mainScope)

    /** The connection info last used for a direct (non-WebRTC) connection — `ServerInfoSection`
     * shows this rather than deriving host/port from the live session, matching the Compose
     * original (`SettingsViewModel.savedConnectionInfo`). */
    fun savedConnectionInfo(): ConnectionInfo? = settingsRepository.connectionInfo.value

    // MARK: - Auth (login/OAuth) — thin wraps over AuthenticationManager, which stays the
    // sole owner of the actual state machine (server-ID-mismatch detection, per-server token
    // lifecycle, abandoned-OAuth-flow recovery). Nothing here re-derives any of that.

    /** Live auth state — same `is`/`as?`-matchable pattern as [sessionState]. Drives
     * `ConnectionSetupStore`'s login-form UI (loading/providers-loaded/authenticated/error). */
    val authState: NativeStateFlow<AuthState> get() = NativeStateFlow(authManager.authState, mainScope)

    /** Wraps `AuthenticationManager.getProviders()`. Swift cancels the returned handle before
     * starting a new load (mirrors `AuthenticationViewModel`'s `flatMapLatest` — cancelling the
     * underlying coroutine here is what makes `getProviders()`'s own "rethrow
     * CancellationException, don't surface as Error" behavior apply). */
    fun fetchAuthProviders(completion: (List<AuthProvider>?) -> Unit, onError: (Throwable) -> Unit): Cancellable =
        NativeSuspend(mainScope) { authManager.getProviders().getOrThrow() }
            .invoke(completion, onError)

    /** Wraps `AuthenticationManager.loginWithCredentials()`. Result surfaces asynchronously via
     * [authState], same as Compose — this completion is just "the call was made." */
    fun loginWithCredentials(
        providerId: String,
        username: String,
        password: String,
        completion: (Unit?) -> Unit,
        onError: (Throwable) -> Unit,
    ): Cancellable =
        NativeSuspend(mainScope) { authManager.loginWithCredentials(providerId, username, password).getOrThrow() }
            .invoke(completion, onError)

    /** Wraps `AuthenticationManager.getOAuthUrl()`. [returnUrl] is the callback the server
     * redirects to; Swift owns it (`OAuthCallbackParser.returnURL`) because Swift is what parses
     * the callback. On success, Swift calls `authManager.startOAuthFlow(oauthUrl:)` directly. */
    fun getOAuthUrl(
        providerId: String,
        returnUrl: String,
        completion: (String?) -> Unit,
        onError: (Throwable) -> Unit,
    ): Cancellable =
        NativeSuspend(mainScope) { authManager.getOAuthUrl(providerId, returnUrl).getOrThrow() }
            .invoke(completion, onError)

    /** Wraps `AuthenticationManager.logout()` — the `AuthCoordinator` path that sets
     * `_isLoggingOut = true` before clearing the token, guarding against a race with the
     * sessionState collector's auto-login-with-saved-token branch. Use this, not
     * `serviceClient.logout()` directly (which `SettingsViewModel.logout()` uses and is not
     * wired to any live UI — see the research this bridge is based on). */
    fun authLogout(completion: () -> Unit): Cancellable =
        NativeSuspend(mainScope) { authManager.logout().getOrThrow() }
            .invoke({ completion() }, { completion() })

    // MARK: - Connection setup (Direct/WebRTC connect, history) — thin wraps over
    // `ServiceClient`/`SettingsRepository`, mirroring `SettingsViewModel` verbatim.

    /** Mirrors `SettingsViewModel.attemptConnection` verbatim, including the bare `toInt()` —
     * safe because callers gate the Connect button on the same host/port validation Compose
     * uses before this is reachable. */
    fun attemptConnection(host: String, port: String, isTls: Boolean) {
        serviceClient.connect(ConnectionInfo(host, port.toInt(), isTls))
    }

    /** Mirrors `SettingsViewModel.attemptWebRTCConnection` verbatim — parses/validates via
     * `RemoteId.parse` in Kotlin rather than exporting its `require()`-guarded constructor to
     * Swift; silently no-ops on an unparseable id, same as the original. */
    fun attemptWebRTCConnection(remoteId: String) {
        RemoteId.parse(remoteId)?.let { serviceClient.connectWebRTC(it) }
    }

    /** "direct"/"webrtc" — plain string, matches `SettingsRepository.preferredConnectionMethod`
     * exactly (not normalized to an enum here, to stay a byte-for-byte mirror of the setting). */
    val preferredConnectionMethod: NativeStateFlow<String>
        get() = NativeStateFlow(settingsRepository.preferredConnectionMethod, mainScope)

    fun setPreferredConnectionMethod(method: String) {
        settingsRepository.setPreferredConnectionMethod(method)
    }

    val webrtcRemoteId: NativeStateFlow<String> get() = NativeStateFlow(settingsRepository.webrtcRemoteId, mainScope)

    fun setWebrtcRemoteId(remoteId: String) {
        settingsRepository.setWebrtcRemoteId(remoteId)
    }

    val connectionHistory: NativeStateFlow<List<ConnectionHistoryEntry>>
        get() = NativeStateFlow(settingsRepository.connectionHistory, mainScope)

    /** Mirrors `SettingsViewModel.removeFromHistory` verbatim — also clears the entry's saved
     * token, not just the history row. */
    fun removeFromHistory(entry: ConnectionHistoryEntry) {
        settingsRepository.removeHistoryEntry(entry.serverIdentifier)
        settingsRepository.setTokenForServer(entry.serverIdentifier, null)
    }

    fun hasCredentialsForDirect(host: String, port: Int, isTls: Boolean): Boolean =
        settingsRepository.getTokenForServer(settingsRepository.getDirectServerIdentifier(host, port, isTls)) != null

    fun hasCredentialsForWebRTC(remoteId: String): Boolean =
        settingsRepository.getTokenForServer(settingsRepository.getWebRTCServerIdentifier(remoteId)) != null

    // MARK: - Now Playing channels (local player → Control Center / lock screen)
    //
    // Consumed by `NowPlayingCoordinator.swift`, the sole writer of Apple's
    // system-media surfaces. Each observer replays the current value on
    // subscribe — late subscribers (foreground return) catch up immediately.
    // Callbacks arrive on the main thread; Swift needs no dispatch hop.
    // `null` means "nothing to present" (no current track).

    /**
     * Subscribe to track metadata changes (identity, titles, artwork URL,
     * duration, long-form flag).
     */
    fun observeNowPlayingTrack(onChanged: (NowPlayingTrack?) -> Unit): Cancellable {
        val job = mainScope.launch {
            mainDataSource.nowPlayingTrack.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    /**
     * Subscribe to transport anchor changes (playing state, position anchor,
     * rate). The anchor timestamp is only meaningful on the Kotlin side;
     * Swift re-stamps arrival with its own clock.
     */
    fun observeNowPlayingTransport(onChanged: (NowPlayingTransport?) -> Unit): Cancellable {
        val job = mainScope.launch {
            mainDataSource.nowPlayingTransport.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    /** Subscribe to queue-mode changes (shuffle, repeat, toggle availability). */
    fun observeNowPlayingModes(onChanged: (NowPlayingModes?) -> Unit): Cancellable {
        val job = mainScope.launch {
            mainDataSource.nowPlayingModes.collect { onChanged(it) }
        }
        return Cancellable { job.cancel() }
    }

    // MARK: - Local player (Sendspin) — settings read/write pairs plus a coarse
    // status feed for the Settings section. Lifecycle is NOT driven from here:
    // `MainDataSource` watches `sendspinEnabled` and starts/stops the player, so
    // the toggle only writes the setting.

    val sendspinEnabled: NativeStateFlow<Boolean>
        get() = NativeStateFlow(settingsRepository.sendspinEnabled, mainScope)

    fun setSendspinEnabled(enabled: Boolean) {
        settingsRepository.setSendspinEnabled(enabled)
    }

    val sendspinDeviceName: NativeStateFlow<String>
        get() = NativeStateFlow(settingsRepository.sendspinDeviceName, mainScope)

    fun setSendspinDeviceName(name: String) {
        settingsRepository.setSendspinDeviceName(name)
    }

    val sendspinUseCustomConnection: NativeStateFlow<Boolean>
        get() = NativeStateFlow(settingsRepository.sendspinUseCustomConnection, mainScope)

    fun setSendspinUseCustomConnection(enabled: Boolean) {
        settingsRepository.setSendspinUseCustomConnection(enabled)
    }

    val sendspinHost: NativeStateFlow<String>
        get() = NativeStateFlow(settingsRepository.sendspinHost, mainScope)

    fun setSendspinHost(host: String) {
        settingsRepository.setSendspinHost(host)
    }

    val sendspinPort: NativeStateFlow<Int>
        get() = NativeStateFlow(settingsRepository.sendspinPort, mainScope)

    fun setSendspinPort(port: Int) {
        settingsRepository.setSendspinPort(port)
    }

    val sendspinPath: NativeStateFlow<String>
        get() = NativeStateFlow(settingsRepository.sendspinPath, mainScope)

    fun setSendspinPath(path: String) {
        settingsRepository.setSendspinPath(path)
    }

    val sendspinUseTls: NativeStateFlow<Boolean>
        get() = NativeStateFlow(settingsRepository.sendspinUseTls, mainScope)

    fun setSendspinUseTls(enabled: Boolean) {
        settingsRepository.setSendspinUseTls(enabled)
    }

    val sendspinRequireEncryption: NativeStateFlow<Boolean>
        get() = NativeStateFlow(settingsRepository.sendspinRequireEncryption, mainScope)

    fun setSendspinRequireEncryption(enabled: Boolean) {
        settingsRepository.setSendspinRequireEncryption(enabled)
    }

    /**
     * Coarse local-player status for the Settings section: "stopped" while no client
     * exists, else a lifecycle label. Kept as a plain string (not the sealed
     * `SendspinState`) so Swift renders text without pattern-matching exported
     * Kotlin subclasses.
     */
    private val sendspinStatusFlow: StateFlow<String> by lazy {
        mainDataSource.sendspinState
            .map { state ->
                when (state) {
                    null -> "stopped"
                    is SendspinState.Idle -> "idle"
                    is SendspinState.Connecting -> "connecting"
                    is SendspinState.Authenticating -> "authenticating"
                    is SendspinState.Handshaking -> "handshaking"
                    is SendspinState.Ready -> "ready"
                    is SendspinState.Buffering -> "buffering"
                    is SendspinState.Synchronized -> "playing"
                    is SendspinState.Reconnecting -> "reconnecting"
                    is SendspinState.Error -> "error"
                }
            }
            .stateIn(mainScope, SharingStarted.Eagerly, "stopped")
    }

    val sendspinStatus: NativeStateFlow<String>
        get() = NativeStateFlow(sendspinStatusFlow, mainScope)

    /** True while a Sendspin client exists (any state) — drives the fields-locked UI. */
    private val sendspinRunningFlow: StateFlow<Boolean> by lazy {
        mainDataSource.sendspinState
            .map { it != null }
            .stateIn(mainScope, SharingStarted.Eagerly, mainDataSource.sendspinState.value != null)
    }

    val sendspinRunning: NativeStateFlow<Boolean>
        get() = NativeStateFlow(sendspinRunningFlow, mainScope)

    /**
     * The player id the local (Sendspin) player is addressed by — `sendspinEffectivePlayerId`,
     * the same value `MainDataSource` compares against to mark a player `isLocal`. Observable
     * because it changes when the connection mode resolves (a legacy UUID becomes the device's
     * public-key identity).
     *
     * Read by `PlayerActivityController` for the one-lock-screen-owner rule: the Live Activity
     * stands down only for the player whose playback the system's own Now Playing card is
     * already presenting, which is this one. Note it is a *persisted* id, non-empty even with
     * the local player switched off — pair it with a live "the local player has something to
     * present" signal (`observeNowPlayingTrack`) rather than treating it as one.
     */
    val localPlayerId: NativeStateFlow<String>
        get() = NativeStateFlow(settingsRepository.sendspinEffectivePlayerId, mainScope)

    fun hasCrashLog(): Boolean = logSharer.hasCrashLog()

    /** Mirrors `SettingsViewModel.shareLogs`/`shareCrashLog` — `LogSharer.ios.kt`'s
     * `presentShareFile` already drives a native `UIActivityViewController` itself, so there's
     * nothing further for Swift to present; these just need to be triggered and awaited. */
    fun shareLogs(chooserTitle: String, completion: () -> Unit) {
        mainScope.launch {
            withContext(Dispatchers.Default) {
                logSharer.prepareLogShareFile(InMemoryLogWriter.getLogText())
            }.let { logSharer.presentShareFile(it, chooserTitle) }
            completion()
        }
    }

    fun shareCrashLog(chooserTitle: String, completion: () -> Unit) {
        mainScope.launch {
            withContext(Dispatchers.Default) { logSharer.prepareCrashLogShareFile() }
                ?.let { logSharer.presentShareFile(it, chooserTitle) }
            completion()
        }
    }

    fun deleteCrashLog() {
        logSharer.deleteCrashLog()
    }

    fun fetchPlaylists(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("playlists", completion) {
            mediaItemRepository.fetchMediaItems(Request.Playlist.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchAlbums(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("albums", completion) {
            mediaItemRepository.fetchMediaItems(Request.Album.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchArtists(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("artists", completion) {
            mediaItemRepository.fetchMediaItems(Request.Artist.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchAudiobooks(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("audiobooks", completion) {
            mediaItemRepository.fetchMediaItems(Request.Audiobook.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    /**
     * Capped, unlike every other `fetchX` in this file: a track library is routinely the
     * largest catalog in the app (often thousands of rows, versus dozens-to-hundreds of
     * artists/albums/playlists), and LibraryListView.swift has no pagination yet. Fetching
     * it unbounded (the `Int.MAX_VALUE` default) was observed to make the round trip +
     * decode large enough that the simulator's own background/foreground lifecycle
     * spuriously fired mid-request, cancelling it — `TRACKS_FETCH_LIMIT` keeps the request
     * small enough that this doesn't happen while native search/pagination isn't built yet.
     */
    fun fetchTracks(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("tracks", completion) {
            mediaItemRepository.fetchMediaItems(Request.Track.list(limit = TRACKS_FETCH_LIMIT)).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchPodcasts(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("podcasts", completion) {
            mediaItemRepository.fetchMediaItems(Request.Podcast.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    fun fetchRadioStations(completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("radioStations", completion) {
            mediaItemRepository.fetchMediaItems(Request.RadioStation.listLibrary()).getOrNull()
                ?: emptyList()
        }
    }

    /**
     * LibraryListView.swift's single entry point, in place of the fetchX above (which
     * CarPlay still calls directly):
     * one method covering every category, with the `search`/`offset`/`sortOption`/
     * `filters` params those don't take. Mirrors LibraryListViewModel.getRequest's
     * per-type dispatch exactly, [filters] included.
     *
     * [offset] + the fixed [LIBRARY_PAGE_SIZE] page is LibraryListViewModel's own
     * offset+limit paging, not a cursor: Swift passes `0` for a fresh load (a route,
     * query, sort, or filter change) and `items.count` to fetch the next page, and
     * treats `result.count >= LIBRARY_PAGE_SIZE` as "there may be more" — same
     * heuristic as `updateStateWithData`'s `hasMore`. `TRACK` no longer needs its own
     * `TRACKS_FETCH_LIMIT`: real pagination caps every request at `LIBRARY_PAGE_SIZE`
     * regardless of type, so the unbounded-fetch problem that constant was working
     * around ([fetchTracks]'s doc) doesn't arise here.
     */
    fun fetchLibraryItems(
        mediaType: MediaType,
        search: String?,
        offset: Int,
        sortOption: SortOption,
        filters: LibraryFilters,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        val orderBy = sortOption.toServerString()
        val favorite = filters.favorite.takeIf { it }
        val providers = filters.providers.takeIf { it.isNotEmpty() }
        val genres = filters.genres.takeIf { it.isNotEmpty() }
        val request = when (mediaType) {
            MediaType.ARTIST -> Request.Artist.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, albumArtistsOnly = filters.albumArtistsOnly,
                providers = providers, genres = genres,
            )
            MediaType.ALBUM -> Request.Album.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, albumTypes = filters.albumTypes.map { it.serverValue },
                providers = providers, genres = genres,
            )
            MediaType.TRACK -> Request.Track.list(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.PLAYLIST -> Request.Playlist.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.AUDIOBOOK -> Request.Audiobook.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.PODCAST -> Request.Podcast.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.RADIO -> Request.RadioStation.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers, genres = genres,
            )
            MediaType.GENRE -> Request.Genre.listLibrary(
                search = search, limit = LIBRARY_PAGE_SIZE, offset = offset, orderBy = orderBy,
                favorite = favorite, providers = providers,
                hideEmpty = filters.hideEmpty.hideEmpty, mediaType = filters.genreMediaType?.serverValue,
            )
            else -> null
        } ?: return completion(emptyList())

        launchFetch("libraryItems:$mediaType:${search.orEmpty()}:$offset:$orderBy:$filters", completion) {
            mediaItemRepository.fetchMediaItems(request).getOrNull() ?: emptyList()
        }
    }

    /**
     * The current persisted [LibraryFilters] for [mediaType], live — mirrors
     * `LibraryListViewModel`'s fold of `settingsRepository.libraryFilters(mediaType)`
     * into its own state. Drives both the filter sheet's initial working copy and the
     * toolbar filter button's active tint (`LibraryFilters.hasActive`, callable
     * directly from Swift as a Kotlin extension property).
     */
    fun libraryFilters(mediaType: MediaType): NativeStateFlow<LibraryFilters> =
        NativeStateFlow(settingsRepository.libraryFilters(mediaType), mainScope)

    /** Persists [filters] for [mediaType] — settings are the source of truth, same as Compose's `setFilters`. */
    fun setLibraryFilters(mediaType: MediaType, filters: LibraryFilters) {
        settingsRepository.setLibraryFilters(mediaType, filters)
    }

    /**
     * Library capability a provider must declare to be offered as a provider-filter option
     * on [mediaType]'s list. Null for types with no provider filter (GENRE). Mirrors
     * LibraryListViewModel.providerFeatureFor exactly.
     */
    private fun providerFeatureFor(mediaType: MediaType): String? = when (mediaType) {
        MediaType.ARTIST -> "library_artists"
        MediaType.ALBUM -> "library_albums"
        MediaType.TRACK -> "library_tracks"
        MediaType.PLAYLIST -> "library_playlists"
        MediaType.RADIO -> "library_radios"
        MediaType.PODCAST -> "library_podcasts"
        MediaType.AUDIOBOOK -> "library_audiobooks"
        else -> null
    }

    /**
     * Provider options for the filter sheet's provider picker — mirrors
     * LibraryListViewModel.loadProviderOptions. Empty (not `null`) for GENRE, which has
     * no provider filter, same as the Compose sheet skipping the load entirely there.
     */
    fun fetchLibraryProviderOptions(mediaType: MediaType, completion: (List<LibraryProviderOption>?) -> Unit) {
        val feature = providerFeatureFor(mediaType) ?: return completion(emptyList())
        launchFetch("libraryProviderOptions:$mediaType", completion) {
            val providers = serviceClient.sendRequest(Request.Library.providers())
                .resultAs<List<ServerProviderInstance>>()
            providers
                ?.filter { it.type == "music" && it.available && feature in it.supportedFeatures }
                ?.map { LibraryProviderOption(it.instanceId, it.name ?: it.domain ?: it.instanceId) }
                ?.sortedBy { it.label.lowercase() }
                ?: emptyList()
        }
    }

    /**
     * Genre options for the filter sheet's genre picker, scoped to genres that actually
     * contain items of [mediaType] — mirrors LibraryListViewModel.loadGenreOptions.
     */
    fun fetchLibraryGenreOptions(mediaType: MediaType, completion: (List<LibraryGenreOption>?) -> Unit) {
        launchFetch("libraryGenreOptions:$mediaType", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Genre.listLibrary(limit = 1000, orderBy = "sort_name", mediaType = mediaType.serverValue),
            ).getOrNull()
                ?.filterIsInstance<Genre>()
                ?.mapNotNull { g -> g.itemId.toIntOrNull()?.let { LibraryGenreOption(it, g.displayName) } }
                ?: emptyList()
        }
    }

    /**
     * Creates a playlist named [name] and resolves to the server-confirmed [Playlist], or
     * `null` on request failure or if no confirming event arrives within the timeout —
     * reuses `createPlaylistAwaitingConfirmation` verbatim (the same helper
     * `ActionsViewModel.createPlaylist` calls for the "add to playlist" sheet's "add new"),
     * rather than `LibraryListViewModel.createPlaylist`'s plainer fire-and-forget: starting
     * the await *before* sending avoids the race where a fast server echo arrives before a
     * listener would otherwise be attached, and gives Swift a definite point to refresh the
     * list from rather than guessing at a delay.
     */
    fun createPlaylist(name: String, completion: (Playlist?) -> Unit) {
        mainScope.launch {
            val result = createPlaylistAwaitingConfirmation(
                name = name,
                itemChanges = mediaItemRepository.itemChanges,
                timeoutMs = FETCH_TIMEOUT_MS,
                sendCreate = { serviceClient.sendRequest(Request.Playlist.create(name)) },
                onError = { log.w { "createPlaylist($name) failed" } },
            )
            completion(result)
        }
    }

    /**
     * One level of the server's `music/browse` provider tree, for the native BrowseView —
     * mirrors `BrowseViewModel.load`. `path`: null for the root, or a `RecommendationFolder`'s
     * `path` (falling back to its `uri`) to descend one level, exactly as
     * `MainNav.Browse(path = item.path ?: item.uri, …)` does on the Compose side. The server
     * returns the whole level in one shot — no pagination here, matching BrowseViewModel's own
     * doc comment.
     */
    fun fetchBrowseItems(path: String?, completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("browse:${path ?: "root"}", completion) {
            mediaItemRepository.fetchMediaItems(Request.Browse.atPath(path)).getOrNull()
                ?: emptyList()
        }
    }

    fun search(query: String, completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("search:$query", completion) {
            val result = mediaItemRepository.search(
                Request.Library.search(
                    query = query,
                    mediaTypes = listOf(
                        MediaType.ARTIST,
                        MediaType.ALBUM,
                        MediaType.TRACK,
                        MediaType.PLAYLIST,
                        MediaType.AUDIOBOOK,
                        MediaType.RADIO,
                    ),
                    limit = 10,
                    libraryOnly = false,
                ),
            ).getOrNull()
            buildList<AppMediaItem> {
                result ?: return@buildList
                addAll(result.artists)
                addAll(result.albums)
                addAll(result.tracks)
                addAll(result.playlists)
                addAll(result.podcasts)
                addAll(result.audiobooks)
                addAll(result.radios)
                addAll(result.genres)
            }
        }
    }

    /**
     * The native Search tab's entry point — mirrors `SearchViewModel.performSearch`'s request
     * shape exactly (limit 200, [mediaTypes] empty = server searches every type), unlike
     * [search] above (a narrower, fixed-6-type, limit-10 stopgap that predates this and stays
     * as-is for its own CarPlay/Siri callers). Returns the type-bucketed [SearchResultData]
     * as-is rather than flattening it, so Swift can group results by type itself.
     */
    fun searchDetailed(
        query: String,
        mediaTypes: List<MediaType>,
        libraryOnly: Boolean,
        completion: (SearchResultData?) -> Unit,
    ) {
        launchFetchSingle("searchDetailed:$query:$mediaTypes:$libraryOnly", completion) {
            mediaItemRepository.search(
                Request.Library.search(
                    query = query,
                    mediaTypes = mediaTypes,
                    limit = SEARCH_RESULT_LIMIT,
                    libraryOnly = libraryOnly,
                ),
            ).getOrNull()
        }
    }

    // MARK: - Drilldown fetchers (same nullable-on-timeout contract)

    fun fetchAlbumsByArtist(
        artist: Artist,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("albumsByArtist:${artist.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Artist.getAlbums(
                    itemId = artist.itemId,
                    providerInstanceIdOrDomain = artist.provider,
                ),
            ).getOrNull()
                ?.filterIsInstance<Album>()
                ?: emptyList()
        }
    }

    fun fetchTracksByAlbum(
        album: Album,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("tracksByAlbum:${album.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Album.getTracks(
                    itemId = album.itemId,
                    providerInstanceIdOrDomain = album.provider,
                ),
            ).getOrNull()
                ?.filterIsInstance<Track>()
                ?: emptyList()
        }
    }

    fun fetchTracksByPlaylist(
        playlist: Playlist,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("tracksByPlaylist:${playlist.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Playlist.getTracks(
                    itemId = playlist.itemId,
                    providerInstanceIdOrDomain = playlist.provider,
                    forceRefresh = null,
                ),
            ).getOrNull()
                ?.filterIsInstance<Track>()
                ?: emptyList()
        }
    }

    fun fetchEpisodesByPodcast(
        podcast: Podcast,
        completion: (List<AppMediaItem>?) -> Unit,
    ) {
        launchFetch("episodesByPodcast:${podcast.itemId}", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Podcast.getEpisodes(
                    itemId = podcast.itemId,
                    providerInstanceIdOrDomain = podcast.provider,
                ),
            ).getOrNull()
                ?.filterIsInstance<PodcastEpisode>()
                ?.clientSorted(
                    SortConfig.defaultFor(SubItemContext.PODCAST_EPISODES),
                    SubItemContext.PODCAST_EPISODES,
                )
                ?: emptyList()
        }
    }

    /**
     * The "Discography" section of the native artist screen — an album list assembled by
     * trying the artist's provider mappings in order and keeping the first non-empty result,
     * same as `ItemDetailsViewModel.loadArtistAlbumSections`'s `all` section. `null` on
     * timeout or when the artist has no provider mappings at all.
     */
    fun fetchArtistAllAlbums(artist: Artist, completion: (List<AppMediaItem>?) -> Unit) {
        mainScope.launch {
            val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                ItemUseCases.fetchArtistItemsAcrossProviders<Album>(mediaItemRepository, artist) {
                        itemId, providerInstance ->
                    Request.Artist.getAlbums(itemId, providerInstance)
                }
            }
            completion(result?.items)
        }
    }

    /** The "Top tracks" section of the native artist screen — same cross-provider contract
     * as [fetchArtistAllAlbums]. */
    fun fetchArtistTopTracks(artist: Artist, completion: (List<AppMediaItem>?) -> Unit) {
        mainScope.launch {
            val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                ItemUseCases.fetchArtistItemsAcrossProviders<Track>(mediaItemRepository, artist) {
                        itemId, providerInstance ->
                    Request.Artist.getTopTracks(itemId, providerInstance)
                }
            }
            completion(result?.items)
        }
    }

    /**
     * The native genre screen's Albums/Artists overview — a mixed list Swift filters by type,
     * mirroring `ItemDetailsViewModel.loadGenreOverview`'s flattening of the server's
     * recommendation folders.
     */
    fun fetchGenreOverview(itemId: String, providerId: String, completion: (List<AppMediaItem>?) -> Unit) {
        launchFetch("genreOverview:$itemId", completion) {
            mediaItemRepository.fetchMediaItems(
                Request.Genre.overview(
                    itemId = itemId,
                    providerInstanceIdOrDomain = providerId,
                ),
            ).getOrNull()
                ?.filterIsInstance<RecommendationFolder>()
                ?.flatMap { it.items.orEmpty() }
                ?: emptyList()
        }
    }

    /**
     * Fetches a single item (Album/Playlist/Podcast/Audiobook/Artist/Genre) by identity, for
     * the native ItemDetailsView hero — mirrors ItemDetailsViewModel.getItemById's request
     * shape. `null` on both an unsupported type and a timed-out/failed fetch — the caller
     * can't tell those apart, but it only needs "show the error state".
     */
    fun fetchItemDetails(
        itemId: String,
        mediaType: MediaType,
        providerId: String,
        completion: (AppMediaItem?) -> Unit,
    ) {
        val request = when (mediaType) {
            MediaType.ALBUM -> Request.Album.get(itemId, providerId)
            MediaType.PLAYLIST -> Request.Playlist.get(itemId, providerId)
            MediaType.PODCAST -> Request.Podcast.get(itemId, providerId)
            MediaType.AUDIOBOOK -> Request.Audiobook.get(itemId, providerId)
            MediaType.ARTIST -> Request.Artist.get(itemId, providerId)
            MediaType.GENRE -> Request.Genre.get(itemId, providerId)
            else -> null
        } ?: return completion(null)

        launchFetchSingle("itemDetails:$mediaType:$itemId", completion) {
            mediaItemRepository.fetchMediaItem(request).getOrNull()
        }
    }

    private inline fun <T> launchFetchSingle(
        label: String,
        crossinline completion: (T?) -> Unit,
        crossinline fetch: suspend () -> T?,
    ) {
        val startMs = currentTimeMillis()
        mainScope.launch {
            val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) { fetch() }
            log.i { "fetch[$label] ${if (result != null) "loaded" else "failed"} in ${currentTimeMillis() - startMs}ms" }
            completion(result)
        }
    }

    // MARK: - Playback

    /**
     * Play [item] on whichever player is currently selected (the Home tab's player
     * picker) — not necessarily this device, unlike [playOnLocalPlayer], which is
     * CarPlay's deliberate always-local override. Mirrors
     * `ItemDetailsViewModel.onPlayClick`'s request shape for the native ItemDetailsView's
     * hero play button and track/episode row taps. False on no selected player or no URI.
     */
    fun playOnSelectedPlayer(item: AppMediaItem, option: QueueOption, endlessMix: Boolean): Boolean {
        val mediaUri = item.mediaUri ?: return false
        val queueId = mainDataSource.selectedPlayer?.queueOrPlayerId ?: return false
        mainScope.launch {
            serviceClient.sendRequest(
                Request.Library.play(
                    media = listOf(mediaUri),
                    queueOrPlayerId = queueId,
                    option = option,
                    endlessMixMode = endlessMix && item !is Genre,
                ),
            )
        }
        return true
    }

    /**
     * Plays an audiobook [item] starting at [chapterPosition], on the currently selected
     * player. Mirrors `ItemDetailsViewModel.onChapterClick`.
     */
    fun playChapterOnSelectedPlayer(item: AppMediaItem, chapterPosition: Int): Boolean {
        val uri = item.referenceUri
        val queueId = mainDataSource.selectedPlayer?.queueOrPlayerId ?: return false
        mainScope.launch {
            serviceClient.sendRequest(
                Request.Library.play(
                    media = listOf(uri),
                    queueOrPlayerId = queueId,
                    option = QueueOption.REPLACE,
                    endlessMixMode = false,
                    startItem = chapterPosition.toString(),
                ),
            )
        }
        return true
    }

    // MARK: - Library Actions (Siri)

    /**
     * Set the favorite flag on an [AppMediaItem]. Drives `INMediaAffinityIntent`
     * mapping from Swift: `like` ⇒ `favorite = true`, `dislike` ⇒ `favorite = false`.
     * MA only tracks favorites as a boolean — dislike removes an existing favorite
     * but cannot record an explicit "do not play this" signal. Adding addresses the item by
     * [AppMediaItem.referenceUri]; removal works by id+mediaType.
     *
     * Returns `true` synchronously once the request is dispatched. Network outcome is
     * fire-and-forget — Swift uses the synchronous return to avoid lying to Siri about
     * success. Both directions are always expressible now that the add path addresses the
     * item by [AppMediaItem.referenceUri] rather than a server-supplied URI that may be
     * missing (or, for podcasts, point at the show's website).
     */
    fun setFavorite(item: AppMediaItem, favorite: Boolean): Boolean =
        setFavorite(item, favorite) { }

    /**
     * [setFavorite] with the server's answer reported through [completion] — `false` when the
     * request was refused (a rejection arrives as a *successful* Result carrying an error
     * payload, hence `isAccepted` rather than `onFailure`) or never made it out. For screens
     * that flip a heart optimistically and have to put it back when the write didn't land;
     * fire-and-forget callers (Siri, the long-press context menu) use the overload above.
     *
     * Always dispatches, so the `Boolean` return is `true` and [completion] always runs; the
     * return is kept for symmetry with the overload above and its Swift call sites.
     */
    fun setFavorite(item: AppMediaItem, favorite: Boolean, completion: (Boolean) -> Unit): Boolean {
        val request = if (favorite) {
            // `referenceUri`, never the raw `uri`: a provider podcast's server-supplied `uri`
            // is the show's website, which the server can't resolve back to the item.
            Request.Library.addFavorite(item.referenceUri)
        } else {
            Request.Library.removeFavorite(item.itemId, item.mediaType)
        }
        mainScope.launch {
            val result = serviceClient.sendRequest(request)
            if (!result.isAccepted) {
                log.e(result.exceptionOrNull()) {
                    "Favorite set to $favorite rejected for ${item.itemId}: " +
                        (result.getOrNull()?.errorDetails ?: "transport failure")
                }
            }
            completion(result.isAccepted)
        }
        return true
    }

    /**
     * Optimistic favorite toggle for the expanded player's heart. Unlike [setFavorite]
     * (Siri/context-menu, fire-and-forget with no local patch), this routes through
     * [MainDataSource.toggleFavorite], which flips the `_favoriteOverrides` overlay
     * immediately — so the heart reacts on the next state emission — rolls back on
     * send failure, and is reconciled by the server's `MediaItemUpdatedEvent`.
     */
    fun toggleFavoriteOptimistic(item: AppMediaItem) = mainDataSource.toggleFavorite(item)

    // MARK: - Item context menu (long-press actions)
    //
    // Which actions apply to a given item is resolved natively in Swift (mirroring
    // `ItemActionResolver.resolveLongClickActions` 1:1, the same "small pure function,
    // port it directly" precedent HomeView.swift's `reconciledRows` already follows) —
    // only the actions that actually touch the server get a bridge method here.
    // `Play Now`/`Insert Next & Play`/`Insert Next`/`Add to Queue`/`Start endless mix` are
    // already covered by [playOnSelectedPlayer] with the matching `QueueOption`/`endlessMix`
    // combo; `Favorite`/`Unfavorite` by [setFavorite].

    /**
     * Whether [item] supports being added to a playlist — mirrors
     * `ItemActionResolver.supportsAddToPlaylist` (Track/Album/RadioStation/PodcastEpisode/
     * Audiobook only; notably not Playlist/Artist/Podcast/Genre).
     */
    fun supportsAddToPlaylist(item: AppMediaItem): Boolean =
        item is Track || item is Album || item is RadioStation || item is PodcastEpisode || item is Audiobook

    /**
     * "Play From Here": plays [parent] (an Album or Playlist) starting at [startItem].
     * Mirrors `ItemDetailsViewModel.onPlayClick`'s `fromHereInParent = true` branch — the
     * request targets the *parent's* URI with `start_item` set to the track/episode's id,
     * not a `play_media` call on the track itself. False on no selected player or no parent URI.
     */
    fun playFromHere(parent: AppMediaItem, startItem: AppMediaItem): Boolean {
        val mediaUri = parent.mediaUri ?: return false
        val queueId = mainDataSource.selectedPlayer?.queueOrPlayerId ?: return false
        mainScope.launch {
            serviceClient.sendRequest(
                Request.Library.play(
                    media = listOf(mediaUri),
                    queueOrPlayerId = queueId,
                    option = QueueOption.REPLACE,
                    endlessMixMode = false,
                    startItem = startItem.itemId,
                ),
            )
        }
        return true
    }

    /**
     * Toggles library membership (add/remove) for [item] — distinct from favorite/unfavorite,
     * which requires the item already be in the library. Mirrors `ActionsViewModel.onLibraryClick`.
     */
    fun setInLibrary(item: AppMediaItem, inLibrary: Boolean): Boolean {
        if (inLibrary) {
            mainScope.launch { serviceClient.sendRequest(Request.Library.add(item.referenceUri)) }
        } else {
            mainScope.launch { serviceClient.sendRequest(Request.Library.remove(item.itemId, item.mediaType)) }
        }
        return true
    }

    /**
     * The user's editable, non-dynamic playlists for the "Add to Playlist" picker — mirrors
     * `ActionsViewModel.getEditablePlaylists`'s filtering exactly (unlike [fetchPlaylists],
     * which returns every library playlist including read-only/smart ones).
     */
    fun fetchEditablePlaylists(completion: (List<Playlist>?) -> Unit) {
        launchFetch("editablePlaylists", completion) {
            mediaItemRepository.fetchMediaItems(Request.Playlist.listLibrary()).getOrNull()
                ?.filterIsInstance<Playlist>()
                ?.filter { it.isEditable && !it.isDynamic }
                ?: emptyList()
        }
    }

    /** Adds [itemUri] to [playlist] — mirrors `ActionsViewModel.addToPlaylist`. */
    fun addToPlaylist(itemUri: String, playlist: Playlist, completion: (Boolean) -> Unit) {
        mainScope.launch {
            val result = serviceClient.sendRequest(
                Request.Playlist.addTracks(playlistId = playlist.itemId, trackUris = listOf(itemUri)),
            )
            completion(result.isAccepted)
        }
    }

    /**
     * Removes the track at [position] (0-based, as currently displayed) from [playlistId] —
     * mirrors `ActionsViewModel.removeFromPlaylist`'s +1 for the server's 1-based indexing.
     */
    fun removeFromPlaylist(playlistId: String, position: Int, completion: (Boolean) -> Unit) {
        mainScope.launch {
            val result = serviceClient.sendRequest(
                Request.Playlist.removeTracks(playlistId = playlistId, positions = listOf(position + 1)),
            )
            completion(result.isAccepted)
        }
    }

    /**
     * Marks [item] played/unplayed — a no-op returning `null` for anything but a
     * PodcastEpisode or Audiobook (the only [MarkableItem]s). The server sends no update
     * event for this, so on success this returns the client-patched item (mirrors
     * `ActionsViewModel.onMarkPlayed`'s `publishLocalChange` optimistic patch) for Swift to
     * splice into its own list state instead of waiting on a refetch.
     */
    fun setMarkPlayed(item: AppMediaItem, played: Boolean, completion: (AppMediaItem?) -> Unit) {
        val markable = item as? MarkableItem ?: return completion(null)
        mainScope.launch {
            val request = if (played) Request.Library.markPlayed(markable) else Request.Library.markUnplayed(markable)
            val result = serviceClient.sendRequest(request)
            if (result.isAccepted) {
                val updated = markable.withPlayed(played)
                mediaItemRepository.publishLocalChange(MediaItemChange.Updated(updated))
                completion(updated)
            } else {
                completion(null)
            }
        }
    }

    // MARK: - Player bar (native mini + expanded player)
    //
    // Thin wraps over MainDataSource — the real state (player list, selection resolution,
    // local-vs-remote command routing/optimistic dispatch) all stays in Kotlin. Every action
    // below resolves the current PlayerData via [currentPlayerData] and calls the
    // PlayerData-based `mainDataSource.playerAction(data, action)` overload — the exact same
    // path Compose's own PlayerControls/PlayersPager use, which routes through
    // PlayerRequestFactory (or LocalPlayerController for the local player). Deliberately NOT
    // the sibling `playerAction(playerId: String, action)` overload: that one has its own
    // hand-duplicated `when` that only covers a subset of PlayerAction's cases (no
    // ToggleShuffle/ToggleRepeatMode/SeekBy/SetPlaybackSpeed/SetPower — they silently no-op via
    // its `else -> Unit`) — found the hard way when the native shuffle/repeat buttons turned out
    // to do nothing. Shuffle/repeat/mute toggles follow the same "pass the current value, Kotlin
    // computes the next one" shape `PlayerRequestFactory.resolve()` already uses server-side
    // (e.g. repeat cycles OFF→ALL→ONE→OFF there, not in Swift). Group volume, DSP, and the
    // rest of PlayerAction's cases stay unreached for now. Queue transfer and the two queue
    // settings the overflow menu carries live further down, under "Player queue".

    /**
     * Library lifecycle changes — favourites, mark-played, add/remove from library — as they
     * happen, so a list already on screen can reconcile in place instead of refetching.
     *
     * `setFavorite` and `setInLibrary` are fire-and-forget: they send the request and rely on the
     * server echoing `MediaItemUpdatedEvent` / `MediaItemDeletedEvent`, which is what arrives
     * here. `setMarkPlayed` additionally publishes an optimistic local change, because the server
     * emits no event for it. Both paths merge into the same flow.
     *
     * A `SharedFlow` with no replay: subscribers see future changes only. That suits the caller —
     * a list is reconciling something it already fetched, so anything older than its own fetch is
     * already reflected in it.
     *
     * **`Deleted` carries a re-keyed item.** `MediaItemRepository` rewrites a deleted library
     * record to its first provider mapping, because the underlying provider item outlives the
     * library record. Swift has to match deletions against a row's provider mappings as well as
     * its own id — see `LibraryListReconciler.removing`.
     */
    val itemChanges: NativeFlow<MediaItemChange>
        get() = NativeFlow(mediaItemRepository.itemChanges, mainScope)

    val playerBarState: NativeStateFlow<PlayerBarState>
        get() = NativeStateFlow(mainDataSource.playerBarState, mainScope)

    /** The selected player as the Live Activity shows it — `PlayerActivityController`'s only input. */
    val liveActivityState: NativeStateFlow<LiveActivitySnapshot>
        get() = NativeStateFlow(mainDataSource.liveActivityState, mainScope)

    fun selectPlayerBarPlayer(playerId: String) = mainDataSource.selectPlayer(playerId)

    fun togglePlayerBarPlayPause(playerId: String) = dispatchPlayerBarAction(playerId, PlayerAction.TogglePlayPause)

    /**
     * Play/pause dispatched from the lock screen Live Activity's button. The intent runs in the
     * app process, which may have just been cold-launched in the background — so unlike every
     * other player-bar bridge this one cannot assume a live connection or loaded players. It:
     *  1. pokes [ServiceClient.onAppForeground] (reconnects a socket the background teardown
     *     dropped; Swift restores the background flag afterwards when no scene is active),
     *  2. waits — bounded — for command readiness and for [playerId] to appear in players data,
     *  3. sends TogglePlayPause and suspends until the request has left the process
     *     ([MainDataSource.playerActionAwaitingSend]; fire-and-forget would race suspension).
     *
     * Completion receives whether the send happened — as a `KotlinBoolean`, `.boolValue` in Swift.
     */
    fun systemTogglePlayPause(playerId: String, completion: (Boolean) -> Unit) {
        mainScope.launch {
            serviceClient.onAppForeground()
            val data = withTimeoutOrNull(SYSTEM_COMMAND_TIMEOUT_MS) {
                serviceClient.isReadyForCommands.first { it }
                mainDataSource.playersData
                    .mapNotNull { state ->
                        (state as? DataState.Data<List<PlayerData>>)?.data
                            ?.firstOrNull { it.playerId == playerId }
                    }
                    .first()
            }
            val sent = data?.let {
                mainDataSource.playerActionAwaitingSend(it, PlayerAction.TogglePlayPause)
            } ?: false
            completion(sent)
        }
    }

    fun skipPlayerBarNext(playerId: String) = dispatchPlayerBarAction(playerId, PlayerAction.Next)

    fun skipPlayerBarPrevious(playerId: String) = dispatchPlayerBarAction(playerId, PlayerAction.Previous)

    fun seekPlayerBar(playerId: String, seconds: Double) =
        dispatchPlayerBarAction(playerId, PlayerAction.SeekTo(seconds.toLong()))

    /**
     * Relative seek for the expanded player's skip-back/skip-forward buttons (spoken-word items).
     *
     * Deliberately [PlayerAction.SeekBy] rather than a position computed in Swift: Swift's
     * `livePosition` is an interpolated ticker, so an offset applied to it drifts from where the
     * player really is. `PlayerRequestFactory.resolve()` reads the live position at send time
     * and clamps the result to `[0, duration]`, which is also what feeds the optimistic
     * position anchor — so the scrubber jumps to the same place the server will report.
     */
    fun seekPlayerBarBy(playerId: String, seconds: Long) =
        dispatchPlayerBarAction(playerId, PlayerAction.SeekBy(seconds))

    /**
     * Seeks to a position read off a chapter-relative scrubber.
     *
     * [chapter] is the one Swift latched when the drag started, not whichever is current when
     * it ends: a boundary crossed mid-drag must not re-base the released value, which would
     * clamp the thumb to the new chapter's start.
     *
     * The conversion is here rather than in Swift so both coordinate systems meet in one
     * place — and so the round-up survives. Truncating a fractional chapter start lands a
     * fraction of a second before it, inside the previous chapter, which reads to the user as
     * the seek having gone to the wrong chapter entirely.
     *
     * @return the absolute position, in seconds, that was actually requested.
     */
    fun seekWithinChapter(playerId: String, chapter: ChapterBarItem, relativeSec: Double): Double {
        val target = chapterSeekSeconds(chapter.startSec + relativeSec.coerceIn(0.0, chapter.durationSec))
        dispatchPlayerBarAction(playerId, PlayerAction.SeekTo(target))
        // Returned so the caller can latch the exact absolute position that was requested.
        // Recomputing it in Swift would miss the round-up and leave the latch waiting on a
        // server position it never quite matches.
        return target.toDouble()
    }

    fun togglePlayerBarShuffle(playerId: String) {
        val enabled = currentPlayerData(playerId)?.queueInfo?.shuffleEnabled ?: return
        dispatchPlayerBarAction(playerId, PlayerAction.ToggleShuffle(enabled))
    }

    fun cyclePlayerBarRepeatMode(playerId: String) {
        val current = currentPlayerData(playerId)?.queueInfo?.repeatMode ?: return
        dispatchPlayerBarAction(playerId, PlayerAction.ToggleRepeatMode(current))
    }

    fun togglePlayerBarMute(playerId: String) {
        val muted = currentPlayerData(playerId)?.player?.currentMuteState ?: return
        dispatchPlayerBarAction(playerId, PlayerAction.ToggleMute(muted))
    }

    fun setPlayerBarVolume(playerId: String, level: Float) =
        dispatchPlayerBarAction(playerId, PlayerAction.VolumeSet(level.toDouble()))

    // Deliberately NOT dispatchPlayerBarAction — see MainDataSource.setSleepTimer's doc:
    // the timer is server-owned for every player and must never take a local-player branch.
    fun setPlayerSleepTimer(playerId: String, seconds: Int) =
        mainDataSource.setSleepTimer(playerId, seconds)

    fun clearPlayerSleepTimer(playerId: String) = mainDataSource.clearSleepTimer(playerId)

    /**
     * Whether the connected server's schema has the `players/sleep_timer` commands
     * ([SLEEP_TIMER_MIN_SCHEMA]). Non-reactive on purpose, same as [getServerId]:
     * Swift evaluates it inside a body that re-runs on every player-bar emission,
     * and the schema only changes across connect/disconnect.
     */
    fun isSleepTimerSupported(): Boolean =
        supportsSleepTimer(
            (serviceClient.sessionState.value as? HasConnectionData)
                ?.connectionData
                ?.serverInfo
                ?.schemaVersion,
        )

    private fun dispatchPlayerBarAction(playerId: String, action: PlayerAction) {
        val data = currentPlayerData(playerId) ?: return
        mainDataSource.playerAction(data, action)
    }

    /**
     * A ticking position source for the expanded player's seek slider — wraps
     * `MainDataSource.positionTracker.observe(queueId)`, the same cold, plays-only-while-playing
     * flow every other now-playing surface (notification, CarPlay) already reads. `Double` is a
     * primitive, so per [NativeFlow]'s own doc it arrives as `KotlinDouble` in Swift — needs
     * `.doubleValue`, same as the already-known `KotlinBoolean` gotcha elsewhere in this file.
     */
    fun observePlayerBarPosition(playerId: String): NativeFlow<Double> {
        val queueId = currentPlayerData(playerId)?.queueOrPlayerId ?: playerId
        return NativeFlow(mainDataSource.positionTracker.observe(queueId), mainScope)
    }

    private fun currentPlayerData(playerId: String): PlayerData? =
        (mainDataSource.playersData.value as? DataState.Data)?.data?.firstOrNull { it.playerId == playerId }

    // MARK: - Player queue
    //
    // All three route through MainDataSource.queueAction(QueueAction) — confirmed (unlike
    // playerAction) to be a single, canonical implementation with no sibling overload to
    // accidentally miss; it's the exact same entry point Compose's own CollapsibleQueue/
    // PlayersPager call. MainDataSource itself already no-ops a MoveItem when to == from, so
    // Swift doesn't need to guard that case before calling.

    fun playQueueItem(queueId: String, queueItemId: String) =
        mainDataSource.queueAction(QueueAction.PlayQueueItem(queueId, queueItemId))

    fun moveQueueItem(queueId: String, queueItemId: String, from: Int, to: Int) =
        mainDataSource.queueAction(QueueAction.MoveItem(queueId, queueItemId, from, to))

    fun removeQueueItem(queueId: String, queueItemId: String) =
        mainDataSource.queueAction(QueueAction.RemoveItems(queueId, listOf(queueItemId)))

    /**
     * Hands the whole queue to another player. [autoplay] maps to the server's `auto_play`:
     * the expanded player's menu passes whether the source was playing, so a paused queue
     * arrives paused and a playing one keeps going.
     */
    fun transferQueue(sourceQueueId: String, targetQueueId: String, autoplay: Boolean) =
        mainDataSource.queueAction(QueueAction.Transfer(sourceQueueId, targetQueueId, autoplay))

    // MARK: - Queue settings (overflow menu)
    //
    // The two toggles take the value as it stands and let Kotlin compute the flip — the same
    // shape as the shuffle/repeat/mute bridges above, and what PlayerRequestFactory expects. All
    // three go through [dispatchPlayerBarAction] (the PlayerData-based overload); the string-id
    // overload's `when` is the incomplete one this file warns about above and would drop them
    // silently.

    fun togglePlayerBarAutoplay(playerId: String, isEnabledNow: Boolean) =
        dispatchPlayerBarAction(playerId, PlayerAction.ToggleDontStopTheMusic(isEnabledNow))

    fun togglePlayerBarCrossfade(playerId: String, isEnabledNow: Boolean) =
        dispatchPlayerBarAction(playerId, PlayerAction.ToggleCrossfade(isEnabledNow))

    /**
     * Sets the queue's playback speed outright (server range 0.5–3.0, 1.0 = normal) — the one
     * menu entry that carries a value rather than a flip. The server accepts it for audiobooks
     * and podcast episodes only and rejects the command for anything else, which is why the
     * Swift row is gated on `isSpokenWord` as well as on the queue reporting a speed at all.
     * Nothing optimistic for remote players: the checkmark moves when the server echoes it.
     */
    fun setPlayerBarPlaybackSpeed(playerId: String, speed: Double) =
        dispatchPlayerBarAction(playerId, PlayerAction.SetPlaybackSpeed(speed))

    // MARK: - Player grouping (native group settings sheet)
    //
    // All six deliberately use the STRING-id `playerAction(playerId, action)` overload, not
    // `dispatchPlayerBarAction`'s data-based one: member actions target child-player ids that
    // aren't necessarily in the visible players list (`currentPlayerData` would return null and
    // silently drop them), and that overload is exactly what Compose's GroupSettingsDialog
    // dispatched through. It handles VolumeSet/ToggleMute and all five Group* cases and
    // re-routes the local player internally — the "incomplete when" trap it has concerns other
    // actions (shuffle/repeat), none of which are dispatched here.

    fun addGroupMember(parentId: String, childId: String) =
        mainDataSource.playerAction(parentId, PlayerAction.GroupManage(toAdd = listOf(childId)))

    fun removeGroupMember(parentId: String, childId: String) =
        mainDataSource.playerAction(parentId, PlayerAction.GroupManage(toRemove = listOf(childId)))

    fun setGroupVolume(playerId: String, level: Float) =
        mainDataSource.playerAction(playerId, PlayerAction.GroupVolumeSet(level.toDouble()))

    fun toggleGroupMute(playerId: String, isMutedNow: Boolean) =
        mainDataSource.playerAction(playerId, PlayerAction.GroupToggleMute(isMutedNow))

    fun setMemberVolume(playerId: String, level: Float) =
        mainDataSource.playerAction(playerId, PlayerAction.VolumeSet(level.toDouble()))

    fun toggleMemberMute(playerId: String, isMutedNow: Boolean) =
        mainDataSource.playerAction(playerId, PlayerAction.ToggleMute(isMutedNow))
}
