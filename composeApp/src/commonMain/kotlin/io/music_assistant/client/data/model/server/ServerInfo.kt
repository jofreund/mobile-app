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
 * 43 is defensible here for the same reason it is upstream: the 39→43 bump was a constant change
 * with no accompanying code, so schemas 40-43 asked nothing of the client. The one capability
 * that did need gating — the recommendations rows/items split in schema 39 — is handled
 * separately by `RECOMMENDATION_ITEMS_SCHEMA` in `MediaItemRepository`, which is already correct.
 */
const val LOCAL_SCHEMA_VERSION = 43

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
