package io.music_assistant.client.di

import io.music_assistant.client.api.DeepLinkBus
import io.music_assistant.client.api.ErrorMessageBus
import io.music_assistant.client.api.KtorServiceClient
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.auth.AuthCoordinator
import io.music_assistant.client.auth.AuthenticationManager
import io.music_assistant.client.connection.ConnectionManager
import io.music_assistant.client.data.MainDataSource
import io.music_assistant.client.data.PlayerPositionTracker
import io.music_assistant.client.data.PlayerRequestFactory
import io.music_assistant.client.data.factory.MediaItemFactory
import io.music_assistant.client.data.factory.PlayerFactory
import io.music_assistant.client.data.factory.QueueFactory
import io.music_assistant.client.data.repository.MediaItemRepository
import io.music_assistant.client.logging.LogSharer
import io.music_assistant.client.settings.SettingsRepository
import io.music_assistant.client.settings.provideSettings
import io.music_assistant.client.ui.AppRootRouter
import io.music_assistant.client.ui.SchemaVersionWarningViewModel
import io.music_assistant.client.utils.NetworkMonitor
import org.koin.core.module.dsl.bind
import org.koin.core.module.dsl.singleOf
import org.koin.dsl.module

fun sharedModule(
    serviceClientConstructor: (SettingsRepository, ErrorMessageBus) -> ServiceClient = ::KtorServiceClient,
) =
    module {
        single { provideSettings() }
        singleOf(::SettingsRepository)
        singleOf(::NetworkMonitor)
        singleOf(::ErrorMessageBus)
        singleOf(::DeepLinkBus)
        singleOf(serviceClientConstructor) { bind<ServiceClient>() }
        singleOf(::LogSharer)
        single(createdAtStart = true) {
            ConnectionManager(
                get(),
                get(),
            )
        }
        single(createdAtStart = true) {
            AuthenticationManager(
                get(),
                get(),
            )
        }  // Eager - needs to start monitoring immediately
        // Expose the AuthCoordinator surface for viewmodels; same singleton instance.
        single<AuthCoordinator> { get<AuthenticationManager>() }
        single(createdAtStart = true) {  // Eager - must start observing sessionState from launch
            AppRootRouter(get(), get())
        }
        single { PlayerPositionTracker() }  // Shared live-position source of truth
        singleOf(::PlayerRequestFactory)    // Pure PlayerAction → Request mapper
        singleOf(::MediaItemFactory)        // Stateless DTO → domain mapper
        singleOf(::PlayerFactory)           // Stateless DTO → domain mapper
        singleOf(::QueueFactory)            // Stateless DTO → domain mapper (depends on MediaItemFactory)
        singleOf(::MediaItemRepository)     // Server DTO/event → client model boundary for UI
        singleOf(::MainDataSource)          // Singleton - held by foreground service
        single(createdAtStart = true) {  // Eager - schema warning must be observable before any host mounts
            SchemaVersionWarningViewModel(get())
        }
    }

/**
 * Cleanup function to properly close all singleton resources.
 * Call this before stopKoin() to ensure proper resource cleanup.
 */
fun cleanupSingletons() {
    // Cleanup is handled by individual components' lifecycle
}
