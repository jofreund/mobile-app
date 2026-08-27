package io.music_assistant.client.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.data.model.server.LOCAL_SCHEMA_VERSION
import io.music_assistant.client.data.model.server.ServerInfo
import io.music_assistant.client.utils.HasConnectionData
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/**
 * Schema-compatibility warning to surface for the connected server.
 *
 * One case, deliberately. There was a second — `SERVER_AHEAD`, a dismissible "the server speaks
 * a newer schema than the app" alert — and it was noise: it fired on every launch against any
 * server newer than [LOCAL_SCHEMA_VERSION] while playback, library, queue and recommendations
 * all worked, because nothing in this client gates on a schema above 39. The only fix available
 * to a user was to dismiss it again. Upstream reached the same conclusion and deleted it
 * (music-assistant/mobile-app@c9e03d71).
 */
enum class SchemaWarning {
    /** Client speaks a schema below the server's minimum supported — unusable. Terminal (must exit). */
    CLIENT_INCOMPATIBLE,
}

/**
 * Drives the schema-compatibility alert (see `AppShellRootView.swift`).
 *
 * Server details arrive before login/autologin, so keying off [ServiceClient.sessionState] warns at
 * the right moment. [distinctUntilChanged] flips the value `null → warning` on each fresh
 * server-info arrival (each real connect), which the alert uses to re-show — matching "every time".
 */
class SchemaVersionWarningViewModel(apiClient: ServiceClient) : ViewModel() {
    /** The compatibility warning to show for the current server, or null when compatible. */
    val warning: StateFlow<SchemaWarning?> =
        apiClient.sessionState
            .map { (it as? HasConnectionData)?.serverInfo?.let(::classify) }
            .distinctUntilChanged()
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    /**
     * A server only becomes incompatible when its floor rises above what this client speaks.
     * Merely trailing the server's *current* schema is not a fault — see [SchemaWarning].
     */
    private fun classify(info: ServerInfo): SchemaWarning? {
        info.minSupportedSchemaVersion?.let {
            if (LOCAL_SCHEMA_VERSION < it) return SchemaWarning.CLIENT_INCOMPATIBLE
        }
        return null
    }
}
