package io.music_assistant.client.data.model.server

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Highest server schema_version this client is built and tested against.
 *
 * Was stuck at 31 — the value inherited when the schema warning was introduced — while upstream
 * moved to 39 and then 43. `SchemaVersionWarningViewModel` compares against this, so a stale
 * value doesn't fail safe: any server reporting a higher `schema_version` raised SERVER_AHEAD on
 * every connect, and a server whose `min_supported_schema_version` had passed 31 would have hit
 * CLIENT_INCOMPATIBLE, which is the terminal dialog that offers only Exit.
 *
 * Tracks upstream's verified-compatible value (53 as of 2026-08-21). The capabilities that needed
 * gating along the way are gated on their own constants: the recommendations rows/items split
 * (39, `RECOMMENDATION_ITEMS_SCHEMA` in `MediaItemRepository`), server-side localization of API
 * strings (32, `SERVER_LOCALIZATION_SCHEMA`), and the 2.10 queue-item `stream_metadata` payload,
 * which is simply optional in the DTO.
 *
 * 54 (2026-08-22): Music Assistant 2.10.0rc4 reports schema 54 with min_supported 28, and the
 * app was raising the dismissible "App-Update empfohlen" alert on every launch against it while
 * playback, library, queue and recommendations all worked. Nothing in this client gates on a
 * schema above 39, so 54 asks nothing of the client either; this is the tested-against value,
 * not a capability.
 */
const val LOCAL_SCHEMA_VERSION = 54

@Serializable
data class ServerInfo(
    @SerialName("server_id") var serverId: String,
    @SerialName("server_version") var serverVersion: String? = null,
    @SerialName("schema_version") var schemaVersion: Int? = null,
    @SerialName("min_supported_schema_version") var minSupportedSchemaVersion: Int? = null,
    @SerialName("base_url") var baseUrl: String? = null,
    // @SerialName("homeassistant_addon") var homeassistantAddon: Boolean? = null,
    // @SerialName("onboard_done") var onboardDone: Boolean? = null
)
