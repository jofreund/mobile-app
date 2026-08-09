package io.music_assistant.client.ui

import com.russhwolf.settings.MapSettings
import io.music_assistant.client.api.Answer
import io.music_assistant.client.api.ConnectionInfo
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.auth.AuthenticationManager
import io.music_assistant.client.data.model.server.ServerInfo
import io.music_assistant.client.data.model.server.User
import io.music_assistant.client.data.model.server.events.Event
import io.music_assistant.client.settings.ConnectionHistoryEntry
import io.music_assistant.client.settings.ConnectionType
import io.music_assistant.client.settings.SettingsRepository
import io.music_assistant.client.utils.AuthProcessState
import io.music_assistant.client.utils.ConnectionData
import io.music_assistant.client.utils.SessionState
import io.music_assistant.client.webrtc.DataChannelWrapper
import io.music_assistant.client.webrtc.WebRTCHttpProxy
import io.music_assistant.client.webrtc.model.RemoteId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * This is a straight extraction of what used to be an untestable
 * `LaunchedEffect`/`remember` tangle inside `TopLevelNavRoot`'s Composable body
 * (splash latch, destination-forcing rules, reconnection banner). See
 * [AppRootRouter]'s doc for why it moved: iOS drives the identical decision
 * from the same singleton, so this suite is the guard against the two
 * diverging.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AppRootRouterTest {
    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private val connectionInfo = ConnectionInfo("host", 8095, isTls = false)

    /** [AuthenticationManager.willAutoLoginOnLaunch] snapshots at construction; no history saved. */
    private fun managerWithoutSavedToken(client: ServiceClient) =
        AuthenticationManager(client, SettingsRepository(MapSettings()))

    /** A saved server + token, so [AuthenticationManager.willAutoLoginOnLaunch] is true. */
    private fun managerWithSavedToken(client: ServiceClient): AuthenticationManager {
        val settings = SettingsRepository(MapSettings())
        settings.addOrUpdateHistoryEntry(
            ConnectionHistoryEntry(
                type = ConnectionType.DIRECT,
                host = connectionInfo.host,
                port = connectionInfo.port,
                isTls = connectionInfo.isTls,
            ),
        )
        val identifier = settings.getDirectServerIdentifier(
            connectionInfo.host,
            connectionInfo.port,
            connectionInfo.isTls,
        )
        settings.setTokenForServer(identifier, "saved-token")
        return AuthenticationManager(client, settings)
    }

    private fun authenticated(wasAutoLogin: Boolean = true) = SessionState.Connected.Direct(
        connectionInfo = connectionInfo,
        connectionData = ConnectionData(
            serverInfo = ServerInfo(serverId = "server-1"),
            user = User(),
            authProcessState = AuthProcessState.NotStarted,
            wasAutoLogin = wasAutoLogin,
            token = "token",
        ),
    )

    private fun awaitingAuth(authProcessState: AuthProcessState = AuthProcessState.NotStarted) =
        SessionState.Connected.Direct(
            connectionInfo = connectionInfo,
            connectionData = ConnectionData(
                serverInfo = ServerInfo(serverId = "server-1"),
                authProcessState = authProcessState,
            ),
        )

    // MARK: - Initial destination

    @Test
    fun `initial destination is SETTINGS when disconnected with no saved token`() {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        assertEquals(AppRootDestination.SETTINGS, router.destination.value)
    }

    @Test
    fun `initial destination is MAIN when a saved token means auto-login will run`() {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithSavedToken(client))
        assertEquals(AppRootDestination.MAIN, router.destination.value)
    }

    @Test
    fun `initial destination is MAIN when already authenticated at construction`() {
        val client = StubServiceClient(initial = authenticated())
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        assertEquals(AppRootDestination.MAIN, router.destination.value)
    }

    // MARK: - Splash

    @Test
    fun `splash is not visible without a saved token to auto-login with`() = runTest {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        runCurrent()
        assertFalse(router.splashVisible.value)
    }

    @Test
    fun `splash is visible while auto-login is in flight`() = runTest {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithSavedToken(client))
        runCurrent()
        assertTrue(router.splashVisible.value, "Precondition: splash up during Disconnected.Initial")

        client.sessionState.value = SessionState.Connecting
        runCurrent()
        assertTrue(router.splashVisible.value)

        client.sessionState.value = awaitingAuth()
        runCurrent()
        assertTrue(router.splashVisible.value, "Still awaiting auth resolution")
    }

    @Test
    fun `splash dismisses on successful auth and never reappears`() = runTest {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithSavedToken(client))
        runCurrent()

        client.sessionState.value = authenticated()
        runCurrent()
        assertFalse(router.splashVisible.value)

        // A later user-initiated reconnect revisits a splash-shaped state —
        // the latch must keep it hidden.
        client.sessionState.value = SessionState.Connecting
        runCurrent()
        assertFalse(router.splashVisible.value, "Latch must survive a later reconnect attempt")
    }

    @Test
    fun `splash dismisses on auth failure and never reappears`() = runTest {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithSavedToken(client))
        runCurrent()

        client.sessionState.value = awaitingAuth(AuthProcessState.Failed("bad token"))
        runCurrent()
        assertFalse(router.splashVisible.value)

        client.sessionState.value = SessionState.Connecting
        runCurrent()
        assertFalse(router.splashVisible.value, "Latch must survive a later reconnect attempt")
    }

    @Test
    fun `cancelAutoLogin disconnects and hides the splash immediately`() = runTest {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithSavedToken(client))
        runCurrent()
        assertTrue(router.splashVisible.value)

        router.cancelAutoLogin()

        assertTrue(client.disconnectByUserCalls > 0)
        assertFalse(router.splashVisible.value)
    }

    // MARK: - Destination switching

    @Test
    fun `destination is preserved during Reconnecting`() = runTest {
        val client = StubServiceClient(initial = authenticated())
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        runCurrent()
        assertEquals(AppRootDestination.MAIN, router.destination.value)

        client.sessionState.value = SessionState.Reconnecting.Direct(attempt = 1, connectionInfo = connectionInfo)
        runCurrent()
        assertEquals(AppRootDestination.MAIN, router.destination.value)
    }

    @Test
    fun `destination is preserved while Backgrounded`() = runTest {
        val client = StubServiceClient(initial = authenticated())
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        runCurrent()

        client.sessionState.value = SessionState.Disconnected.Backgrounded
        runCurrent()
        assertEquals(AppRootDestination.MAIN, router.destination.value)
    }

    @Test
    fun `destination forces SETTINGS on a terminal disconnect`() = runTest {
        val client = StubServiceClient(initial = authenticated())
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        runCurrent()

        client.sessionState.value = SessionState.Disconnected.Error(reason = null)
        runCurrent()
        assertEquals(AppRootDestination.SETTINGS, router.destination.value)
    }

    @Test
    fun `destination forces MAIN when auto-login succeeds`() = runTest {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithSavedToken(client))
        runCurrent()
        assertEquals(AppRootDestination.MAIN, router.destination.value, "Biased to Main pre-resolution")

        client.sessionState.value = authenticated(wasAutoLogin = true)
        runCurrent()
        assertEquals(AppRootDestination.MAIN, router.destination.value)
    }

    @Test
    fun `authenticating without wasAutoLogin does not force a screen change`() = runTest {
        val client = StubServiceClient()
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        runCurrent()
        router.requestSettings()
        assertEquals(AppRootDestination.SETTINGS, router.destination.value)

        // A manual (non-auto) login succeeding shouldn't yank the user off
        // the Settings screen they're sitting on — Settings itself navigates
        // via goHome() once its own UI decides to.
        client.sessionState.value = authenticated(wasAutoLogin = false)
        runCurrent()
        assertEquals(AppRootDestination.SETTINGS, router.destination.value)
    }

    @Test
    fun `destination forces SETTINGS when auth is rejected`() = runTest {
        val client = StubServiceClient(initial = authenticated())
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        runCurrent()

        client.sessionState.value = awaitingAuth(AuthProcessState.Failed("expired token"))
        runCurrent()
        assertEquals(AppRootDestination.SETTINGS, router.destination.value)
    }

    @Test
    fun `requestSettings and requestHome override immediately regardless of session state`() {
        val client = StubServiceClient(initial = authenticated())
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        assertEquals(AppRootDestination.MAIN, router.destination.value)

        router.requestSettings()
        assertEquals(AppRootDestination.SETTINGS, router.destination.value)

        router.requestHome()
        assertEquals(AppRootDestination.MAIN, router.destination.value)
    }

    // MARK: - Banner

    @Test
    fun `bannerState reflects Reconnecting when online and NoNetwork when offline and null otherwise`() = runTest {
        val client = StubServiceClient(initial = authenticated())
        val router = AppRootRouter(client, managerWithoutSavedToken(client))
        runCurrent()
        assertNull(router.bannerState.value)

        client.sessionState.value = SessionState.Reconnecting.Direct(
            attempt = 3,
            connectionInfo = connectionInfo,
            isOnline = true,
        )
        runCurrent()
        assertEquals(AppBannerState.Reconnecting(3), router.bannerState.value)

        client.sessionState.value = SessionState.Reconnecting.Direct(
            attempt = 3,
            connectionInfo = connectionInfo,
            isOnline = false,
        )
        runCurrent()
        assertEquals(AppBannerState.NoNetwork, router.bannerState.value)

        client.sessionState.value = authenticated()
        runCurrent()
        assertNull(router.bannerState.value)
    }
}

private class StubServiceClient(
    initial: SessionState = SessionState.Disconnected.Initial,
) : ServiceClient {
    override val sessionState = MutableStateFlow(initial)
    override val isReadyForCommands = MutableStateFlow(false)
    override val webRTCHttpProxy: WebRTCHttpProxy? = null
    override val events: Flow<Event<out Any>> = emptyFlow()
    override val webrtcSendspinChannel: DataChannelWrapper? = null
    override val foregroundEvents: Flow<Unit> = emptyFlow()

    var disconnectByUserCalls = 0
        private set

    override suspend fun sendRequest(request: Request): Result<Answer> = awaitCancellation()
    override suspend fun login(username: String, password: String): Unit = awaitCancellation()
    override suspend fun authorize(token: String, isAutoLogin: Boolean) = Unit
    override fun logout() = Unit
    override fun resolveImageUrl(
        path: String,
        provider: String,
        isRemotelyAccessible: Boolean,
        proxyId: String?,
    ): String? = null
    override fun rebaseServerImageUrl(rawUrl: String): String? = null
    override fun forceWebRTCReconnect() = Unit
    override fun onAppForeground() = Unit
    override fun onAppBackground() = Unit
    override fun disconnectByUser() {
        disconnectByUserCalls++
    }
    override fun connect(connection: ConnectionInfo) = Unit
    override fun connectWebRTC(remoteId: RemoteId) = Unit
    override fun onPlaybackActive() = Unit
    override fun onPlaybackInactive() = Unit
    override fun forceDisconnect(reason: Exception) = Unit
    override fun noServer() = Unit
}
