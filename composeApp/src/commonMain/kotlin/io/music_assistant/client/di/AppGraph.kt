package io.music_assistant.client.di

import co.touchlab.kermit.Logger
import co.touchlab.kermit.Severity
import com.russhwolf.settings.Settings
import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.webrtc.WebRtcClient
import io.ktor.serialization.kotlinx.KotlinxWebsocketSerializationConverter
import io.ktor.utils.io.ExperimentalKtorApi
import io.music_assistant.client.api.ErrorMessageBus
import io.music_assistant.client.api.KtorServiceClient
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.auth.AuthenticationManager
import io.music_assistant.client.connection.ConnectionManager
import io.music_assistant.client.data.LocalPlayerController
import io.music_assistant.client.data.MainDataSource
import io.music_assistant.client.data.PlayerPositionTracker
import io.music_assistant.client.data.PlayerRequestFactory
import io.music_assistant.client.data.ResumePointResolver
import io.music_assistant.client.data.UserPreferences
import io.music_assistant.client.data.factory.MediaItemFactory
import io.music_assistant.client.data.factory.PlayerFactory
import io.music_assistant.client.data.factory.QueueFactory
import io.music_assistant.client.data.repository.MediaItemRepository
import io.music_assistant.client.logging.InMemoryLogWriter
import io.music_assistant.client.logging.LogSharer
import io.music_assistant.client.logging.platformLogWriters
import io.music_assistant.client.platform.PlatformContext
import io.music_assistant.client.player.MediaPlayerController
import io.music_assistant.client.player.sendspin.SendspinClientFactory
import io.music_assistant.client.player.sendspin.identity.SendspinKeyStore
import io.music_assistant.client.player.sendspin.identity.SettingsSendspinKeyStore
import io.music_assistant.client.settings.SettingsRepository
import io.music_assistant.client.utils.NetworkMonitor
import io.music_assistant.client.utils.createPlatformHttpClient
import io.music_assistant.client.utils.myJson

/**
 * The app's object graph, wired by hand.
 *
 * This replaced Koin. The graph is small, has one consumer (`KmpHelper`), never changes at
 * runtime and has no scopes — everything a DI container is for was absent, while its costs
 * were real: reflection-free but still a registry walked at every `inject()`, a dependency
 * the framework had to link, and wiring that could only be checked by running the app.
 * Here a missing dependency is a compile error, construction order is the order on the page,
 * and the two singletons that must observe from launch are plainly the two non-lazy ones
 * with a comment saying so.
 *
 * Laziness mirrors what Koin did: singles were created on first use, except
 * [connectionManager] and [authManager], which were `createdAtStart`. The heavy objects —
 * the data source, the local player, the Sendspin factory — stay lazy, so a launch that never
 * touches them pays nothing.
 *
 * Platform inputs come in through the constructor; there is no `expect` here. [webRtcClient]
 * is a [Lazy] because the Ktor WebRTC engine is only needed once a remote connection starts.
 */
@OptIn(ExperimentalKtorApi::class)
class AppGraph(
    settingsStore: Settings,
    platformContext: PlatformContext,
    webRtcClient: Lazy<WebRtcClient>,
) {
    val settingsRepository = SettingsRepository(settingsStore)
    val networkMonitor = NetworkMonitor(platformContext)
    val errorBus = ErrorMessageBus()
    val logSharer = LogSharer(platformContext)

    /**
     * Shared HttpClient for the WebRTC signaling WebSocket and for artwork fetched over the
     * data-channel proxy (`KmpHelper.loadArtworkBytes`).
     */
    val webrtcHttpClient: HttpClient = createPlatformHttpClient {
        install(WebSockets) {
            contentConverter = KotlinxWebsocketSerializationConverter(myJson)
        }
    }

    val serviceClient: ServiceClient = KtorServiceClient(
        settings = settingsRepository,
        errorBus = errorBus,
        networkMonitor = networkMonitor,
        webrtcHttpClient = webrtcHttpClient,
        webRtcClient = webRtcClient,
    )

    // Eager: both observe sessionState from launch (auto-connect, auto-login).
    val connectionManager = ConnectionManager(serviceClient, settingsRepository)
    val authManager = AuthenticationManager(serviceClient, settingsRepository)

    val positionTracker = PlayerPositionTracker()
    val userPreferences = UserPreferences()
    val playerRequestFactory = PlayerRequestFactory(positionTracker, userPreferences)
    val mediaItemFactory = MediaItemFactory(serviceClient)
    val playerFactory = PlayerFactory(serviceClient)
    val queueFactory = QueueFactory(mediaItemFactory)
    val resumePointResolver = ResumePointResolver(serviceClient, mediaItemFactory)
    val mediaItemRepository by lazy { MediaItemRepository(serviceClient, mediaItemFactory) }

    val mediaPlayerController by lazy { MediaPlayerController(platformContext) }
    private val sendspinKeyStore: SendspinKeyStore by lazy { SettingsSendspinKeyStore(settingsStore) }
    val sendspinClientFactory by lazy {
        SendspinClientFactory(
            settings = settingsRepository,
            mediaPlayerController = mediaPlayerController,
            serviceClient = serviceClient,
            networkMonitor = networkMonitor,
            keyStore = sendspinKeyStore,
        )
    }
    val localPlayerController by lazy {
        LocalPlayerController(
            settings = settingsRepository,
            apiClient = serviceClient,
            mediaPlayerController = mediaPlayerController,
            sendspinClientFactory = sendspinClientFactory,
            playerRequestFactory = playerRequestFactory,
            resumePointResolver = resumePointResolver,
            positionTracker = positionTracker,
            userPreferences = userPreferences,
            errorBus = errorBus,
        )
    }
    val mainDataSource by lazy {
        MainDataSource(
            settings = settingsRepository,
            apiClient = serviceClient,
            mediaPlayerController = mediaPlayerController,
            localPlayerController = localPlayerController,
            playerRequestFactory = playerRequestFactory,
            resumePointResolver = resumePointResolver,
            positionTracker = positionTracker,
            mediaItemFactory = mediaItemFactory,
            playerFactory = playerFactory,
            queueFactory = queueFactory,
            userPreferences = userPreferences,
        )
    }

    companion object {
        private var instance: AppGraph? = null

        /** The process-wide graph. Throws before [start]; the bridge is never reached before it. */
        val shared: AppGraph
            get() = checkNotNull(instance) { "AppGraph.start() has not run" }

        /**
         * Configures logging and installs [graph] as [shared]. Idempotent: a second call keeps
         * the first graph, so the one entry point (`bootstrapKmp`) can stay belt-and-braces.
         */
        fun start(graph: () -> AppGraph, verboseLogging: Boolean) {
            if (instance != null) return
            // Release builds drop Debug/Verbose logs: the WebSocket layer emits ~4 debug
            // lines/sec for the idle clock-sync heartbeat, which otherwise floods (and evicts
            // useful entries from) InMemoryLogWriter for the entire session.
            Logger.setMinSeverity(if (verboseLogging) Severity.Verbose else Severity.Info)
            // setLogWriters (not addLogWriter) so each platform's console sink replaces
            // Kermit's default rather than doubling it: on iOS the default NSLog writer
            // renders every line as <private>, which would otherwise duplicate the public
            // os.Logger bridge.
            Logger.setLogWriters(listOf(InMemoryLogWriter) + platformLogWriters())
            instance = graph()
        }
    }
}
