package io.music_assistant.client.auth

import co.touchlab.kermit.Logger
import io.music_assistant.client.api.ConnectionLostException
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.data.model.server.AuthProvider
import io.music_assistant.client.data.model.server.LoginResponse
import io.music_assistant.client.data.model.server.OauthUrl
import io.music_assistant.client.data.model.server.User
import io.music_assistant.client.data.model.server.supportsAppSignIn
import io.music_assistant.client.settings.ConnectionType
import io.music_assistant.client.settings.SettingsRepository
import io.music_assistant.client.settings.getServerIdentifier
import io.music_assistant.client.utils.AuthProcessState
import io.music_assistant.client.utils.DataConnectionState
import io.music_assistant.client.utils.SessionState
import io.music_assistant.client.utils.mainDispatcher
import io.music_assistant.client.utils.resultAs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

sealed class AuthState {
    data object Idle : AuthState()
    data object Loading : AuthState()
    data class ProvidersLoaded(val providers: List<AuthProvider>) : AuthState()
    data class Authenticated(val user: User) : AuthState()
    data class Error(val message: String) : AuthState()
}

private val log = Logger.withTag("AuthMgr")

class AuthenticationManager(
    private val serviceClient: ServiceClient,
    private val settings: SettingsRepository,
) : AuthCoordinator {
    private val scope = CoroutineScope(SupervisorJob() + mainDispatcher)

    private val _authState = MutableStateFlow<AuthState>(AuthState.Idle)
    override val authState: StateFlow<AuthState> = _authState.asStateFlow()

    // OAuthHandler will be set by platform (e.g., MainActivity on Android)
    var oauthHandler: OAuthHandler? = null

    // True while an OAuth browser is open and we're awaiting its deep-link callback.
    private var awaitingOAuthCallback = false

    /**
     * The sign-in that returns to the app (server 2.11, Remote Access), waiting for its
     * authorization code. Only this app run holds the PKCE verifier.
     */
    private var pendingAppSignIn: AppSignIn? = null

    // Flag to prevent auto-login during intentional logout - using StateFlow for proper synchronization
    private val _isLoggingOut = MutableStateFlow(false)
    private val isLoggingOut: Boolean
        get() = _isLoggingOut.value

    /**
     * Snapshot at construction: will the cold-launch auto-connect produce a silent auto-login?
     * True iff the most-recent saved server has a saved token. Mirrors the identifier resolution
     * used by the [init] block below and by `KtorServiceClient.init`'s auto-connect path.
     */
    val willAutoLoginOnLaunch: Boolean = run {
        val mostRecent = settings.connectionHistory.value.firstOrNull() ?: return@run false
        val identifier = when (mostRecent.type) {
            ConnectionType.DIRECT -> mostRecent.connectionInfo?.let {
                settings.getDirectServerIdentifier(it.host, it.port, it.isTls)
            }
            ConnectionType.WEBRTC -> mostRecent.remoteId?.let {
                settings.getWebRTCServerIdentifier(it)
            }
        } ?: return@run false
        settings.getTokenForServer(identifier) != null
    }

    /**
     * Whether a token is stored for the server [state] is connected to. When this is false
     * in `AwaitingAuth(NotStarted)`, nothing will ever advance the session — the user has to
     * log in — so callers (router, request gate) must treat that state as terminal rather
     * than "auto-login is about to run".
     */
    fun hasSavedTokenFor(state: SessionState.Connected): Boolean =
        settings.getTokenForServer(settings.getServerIdentifier(state)) != null

    init {
        // Monitor session state to update auth UI state
        scope.launch {
            serviceClient.sessionState.collect { state ->
                if (state is SessionState.Connected) {
                    when (val dataConnectionState = state.dataConnectionState) {
                        is DataConnectionState.AwaitingAuth -> {
                            when (dataConnectionState.authProcessState) {
                                AuthProcessState.NotStarted -> {
                                    // Try auto-login with saved token (unless we're intentionally logging out)
                                    if (isLoggingOut) {
                                        log.i { "AwaitingAuth(NotStarted) — skipping auto-login (logging out)" }
                                    } else {
                                        val serverIdentifier = settings.getServerIdentifier(state)
                                        val token = settings.getTokenForServer(serverIdentifier)
                                        if (token == null) {
                                            log.i { "AwaitingAuth(NotStarted) — no saved token for server" }
                                        } else {
                                            log.i { "AwaitingAuth(NotStarted) — auto-login with saved token" }

                                            val currentServerId =
                                                dataConnectionState.serverInfo.serverId
                                            val previousServerId =
                                                settings.getIdForServer(serverIdentifier)
                                            if (previousServerId == null || currentServerId == previousServerId) {
                                                authorizeWithSavedToken(token)
                                            } else {
                                                serviceClient.forceDisconnect(
                                                    ServerIdMismatchException(),
                                                )
                                            }
                                        }
                                    }
                                }

                                AuthProcessState.InProgress -> {
                                    log.i { "AwaitingAuth(InProgress)" }
                                    _authState.value = AuthState.Loading
                                }

                                is AuthProcessState.Failed -> {
                                    val serverIdentifier = settings.getServerIdentifier(state)
                                    settings.setTokenForServer(serverIdentifier, null)
                                    log.i { "Cleared token for server due to auth failure" }

                                    log.i {
                                        "AwaitingAuth(Failed): " +
                                            dataConnectionState.authProcessState.reason
                                    }
                                    _authState.value =
                                        AuthState.Error(dataConnectionState.authProcessState.reason)
                                }

                                AuthProcessState.LoggedOut -> {
                                    val serverIdentifier = settings.getServerIdentifier(state)
                                    settings.setTokenForServer(serverIdentifier, null)
                                    log.d { "Cleared token for server" }

                                    log.i { "AwaitingAuth(LoggedOut)" }
                                    _authState.value = AuthState.Idle
                                }
                            }
                        }

                        is DataConnectionState.Authenticated -> {
                            state.user?.let { user ->
                                log.i { "Authenticated" }
                                _authState.value = AuthState.Authenticated(user)

                                val serverIdentifier = settings.getServerIdentifier(state)
                                val serverId = dataConnectionState.serverInfo.serverId
                                settings.setIdForServer(serverIdentifier, serverId)
                                settings.setTokenForServer(
                                    serverIdentifier,
                                    dataConnectionState.token,
                                )
                            }
                        }

                        DataConnectionState.AwaitingServerInfo -> {
                            // Logged so a stuck reconnect (no `server/hello`) is observable.
                            log.i { "AwaitingServerInfo" }
                        }
                    }
                }
            }
        }

        // Recover from an abandoned OAuth flow: if the user backs out of the
        // external browser, no callback arrives and authState is stuck on
        // Loading. Only for handlers that cannot report the cancellation
        // themselves — an in-app session does, and it never backgrounds the app,
        // so for it this heuristic could only ever fire spuriously.
        scope.launch {
            serviceClient.foregroundEvents.collect {
                if (oauthHandler?.reportsCancellation == true) return@collect
                if (awaitingOAuthCallback) log.i { "OAuth flow abandoned (foregrounded without callback)" }
                cancelOAuthFlow(reason = null)
            }
        }
    }

    override suspend fun getProviders(): Result<List<AuthProvider>> {
        return try {
            _authState.value = AuthState.Loading
            val response = serviceClient.sendRequest(Request.Auth.providers())

            response.exceptionOrNull()?.let { cause ->
                // The transport dropped the request (the server closes the socket on
                // `auth/logout`), so a reconnect follows and the providers load again on the
                // new socket. An error here would sit on the login screen until then.
                if (cause is ConnectionLostException) return Result.failure(cause)
                val error = "Failed to fetch auth providers"
                _authState.value = AuthState.Error(error)
                return Result.failure(Exception(error))
            }

            response.resultAs<List<AuthProvider>>()?.filter(::canSignIn)?.let { providers ->
                _authState.value = AuthState.ProvidersLoaded(providers)
                Result.success(providers)
            } ?: run {
                val error = "Failed to parse providers"
                _authState.value = AuthState.Error(error)
                Result.failure(Exception(error))
            }
        } catch (e: CancellationException) {
            // Coroutine cancellation (e.g. AuthenticationViewModel's flatMapLatest
            // switching loads on a session-state change) must propagate, not be
            // swallowed by the broad catch below — otherwise it would spuriously
            // drive authState to Error on every disconnect/connection-type switch.
            throw e
        } catch (e: Exception) {
            val error = e.message ?: "Exception fetching providers"
            _authState.value = AuthState.Error(error)
            Result.failure(e)
        }
    }

    @Suppress("UnusedParameter") // providerId reserved — current server login API doesn't yet route per-provider
    override suspend fun loginWithCredentials(
        providerId: String,
        username: String,
        password: String,
    ): Result<Unit> {
        return try {
            _isLoggingOut.value = false  // Reset flag when user explicitly logs in
            _authState.value = AuthState.Loading
            serviceClient.login(username, password)
            Result.success(Unit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val error = e.message ?: "Login failed"
            _authState.value = AuthState.Error(error)
            Result.failure(e)
        }
    }

    /** A failure shows on the login screen, because the sign-in never reaches the browser. */
    override suspend fun getOAuthUrl(provider: AuthProvider, returnUrl: String): Result<String> =
        requestOAuthUrl(provider, returnUrl).onFailure {
            log.w(it) { "OAuth URL not received" }
            _authState.value = AuthState.Error(it.message ?: "Failed to get OAuth URL")
        }

    private suspend fun requestOAuthUrl(provider: AuthProvider, returnUrl: String): Result<String> {
        return try {
            val pkce = if (returnsToApp(provider)) Pkce.create() else null
            val response = serviceClient.sendRequest(
                Request.Auth.authorizationUrl(provider.id, returnUrl, pkce?.challenge),
            )

            if (response.isFailure) {
                return Result.failure(Exception("Failed to get OAuth URL"))
            }

            val oauthUrl = response.resultAs<OauthUrl>()
                ?: return Result.failure(Exception("Failed to parse OAuth URL"))
            val url = oauthUrl.url
                ?: return Result.failure(Exception(oauthUrl.error ?: "Failed to get OAuth URL"))
            pendingAppSignIn = pkce?.let {
                val state = oauthUrl.state
                    ?: return Result.failure(Exception("No sign-in state received"))
                AppSignIn(state, it.verifier)
            }
            Result.success(url)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * The browser returns to the app only over Remote Access, from server 2.11, and only
     * when the provider is reachable from outside the home network. Otherwise the server's
     * own callback page completes the sign-in, as on server 2.10. Ported from upstream #1225.
     */
    private fun returnsToApp(provider: AuthProvider): Boolean {
        if (!provider.supportsRemoteApp) return false
        val session = serviceClient.sessionState.value as? SessionState.Connected.WebRTC ?: return false
        return supportsAppSignIn(session.serverInfo?.schemaVersion)
    }

    /**
     * Over Remote Access, a redirect provider works only when the browser can come back: to the
     * app, or to the server's External URL. Otherwise the server sends the browser to its internal
     * address. The web frontend hides the provider in the same case.
     */
    private fun canSignIn(provider: AuthProvider): Boolean {
        val serverInfo = (serviceClient.sessionState.value as? SessionState.Connected.WebRTC)
            ?.serverInfo ?: return true
        return !provider.requiresRedirect ||
            returnsToApp(provider) ||
            !serverInfo.externalUrl.isNullOrBlank()
    }

    override fun startOAuthFlow(oauthUrl: String): Result<Unit> {
        val handler = oauthHandler
        if (handler == null) {
            val error = "OAuth not supported on this platform"
            _authState.value = AuthState.Error(error)
            return Result.failure(Exception(error))
        }

        return try {
            _authState.value = AuthState.Loading
            // Set BEFORE the call, not after: a handler that fails synchronously
            // reports it through cancelOAuthFlow() from inside openOAuthUrl, and
            // setting the flag afterwards would resurrect a flow that already ended.
            awaitingOAuthCallback = true
            handler.openOAuthUrl(oauthUrl)
            Result.success(Unit)
        } catch (e: Exception) {
            awaitingOAuthCallback = false
            val error = e.message ?: "OAuth flow failed"
            _authState.value = AuthState.Error(error)
            Result.failure(e)
        }
    }

    /**
     * End a pending OAuth flow that produced no token: the user dismissed the auth
     * session, or presenting it failed.
     *
     * Idempotent and a no-op when no flow is pending, so the handler may call it
     * without tracking whether anything else already settled the flow. [reason] is
     * shown to the user; a plain dismissal passes null and drops back to [AuthState.Idle]
     * silently.
     */
    fun cancelOAuthFlow(reason: String?) {
        if (!awaitingOAuthCallback || _authState.value !is AuthState.Loading) return
        awaitingOAuthCallback = false
        log.i { "OAuth flow cancelled${reason?.let { ": $it" } ?: ""}" }
        _authState.value = reason?.let { AuthState.Error(it) } ?: AuthState.Idle
    }

    // Reading a callback URL is Swift's job now (`OAuthCallbackParser` in `DeepLinks.swift`);
    // both delivery paths there end in [handleOAuthCallback] or [cancelOAuthFlow].

    /** The server's own callback page finished the sign-in and returned an access token. */
    fun handleOAuthCallback(token: String) = completeOAuthSignIn { token }

    /**
     * The sign-in returned to the app with an authorization code (server 2.11, Remote Access).
     * Only this app run can complete it, because only it holds the PKCE verifier; a code for
     * another sign-in, for example one started before the app was restarted, can only fail.
     */
    fun handleAuthorizationCode(code: String, state: String) {
        val signIn = pendingAppSignIn?.takeIf { it.state == state } ?: run {
            log.w { "OAuth: authorization code for an unknown sign-in" }
            cancelOAuthFlow("This sign-in has expired. Please try again.")
            return
        }
        pendingAppSignIn = null
        completeOAuthSignIn { exchangeAuthorizationCode(code, state, signIn.codeVerifier) }
    }

    /**
     * Sends `auth/exchange` for the access token, or returns null after showing why not. The
     * server accepts a code once, so a failure here ends the sign-in.
     */
    private suspend fun exchangeAuthorizationCode(code: String, state: String, verifier: String): String? {
        val answer = serviceClient.sendRequest(
            Request.Auth.exchange(state, code, verifier, settings.deviceName.value),
        ).getOrElse {
            log.w(it) { "OAuth: code exchange not answered" }
            _authState.value = AuthState.Error("Sign-in failed. Please try again.")
            return null
        }
        val response = answer.resultAs<LoginResponse>()
        return response?.token?.takeIf { response.success && it.isNotBlank() } ?: run {
            log.w { "OAuth: code exchange refused: ${response?.error}" }
            _authState.value = AuthState.Error(response?.error ?: "Sign-in failed")
            null
        }
    }

    /** Waits for a session that can authorize, then signs in with the token [token] yields. */
    private fun completeOAuthSignIn(token: suspend () -> String?) {
        Logger.d("OAuth callback received")
        // Clear synchronously (before the launch) so the foreground collector,
        // which fires after this on the success path, sees no pending flow.
        awaitingOAuthCallback = false
        _isLoggingOut.value = false
        scope.launch {
            _authState.value = AuthState.Loading

            // Wait for transport + server/hello (authorize() silently no-ops without
            // a Connected session). The foreground/JIT recovery path elsewhere in the
            // pipeline will drive the reconnect — we just wait for it to land.
            val ready = withTimeoutOrNull(CONNECT_WAIT_MS) {
                serviceClient.sessionState.first {
                    it is SessionState.Connected && it.serverInfo != null
                }
            }
            if (ready == null) {
                Logger.e("OAuth: connection timeout — cannot authorize")
                _authState.value = AuthState.Error("Connection timeout. Please try again.")
                return@launch
            }
            try {
                val accessToken = token() ?: return@launch
                serviceClient.authorize(accessToken, isAutoLogin = false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Logger.e(e) { "Authorization failed" }
                _authState.value = AuthState.Error(e.message ?: "Authorization failed")
            }
        }
    }

    private suspend fun authorizeWithSavedToken(token: String) {
        try {
            serviceClient.authorize(token, isAutoLogin = true)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Silent failure - user will see auth UI
        }
    }

    override suspend fun logout(): Result<Unit> {
        pendingAppSignIn = null
        return try {
            // Set flag FIRST, before any async operations
            _isLoggingOut.value = true
            val currentState = serviceClient.sessionState.value
            val serverIdentifier = settings.getServerIdentifier(currentState)
            if (serverIdentifier != null) {
                settings.setTokenForServer(serverIdentifier, null)
            }

            serviceClient.logout()
            _authState.value = AuthState.Idle
            // Keep the flag set to prevent auto-login until user explicitly logs in again
            Result.success(Unit)
        } catch (e: Exception) {
            _isLoggingOut.value = false
            Result.failure(e)
        }
    }

    fun close() {
        scope.cancel()
    }

    private data class AppSignIn(val state: String, val codeVerifier: String)

    private companion object {
        const val CONNECT_WAIT_MS = 10_000L
    }
}

class ServerIdMismatchException : Exception()
