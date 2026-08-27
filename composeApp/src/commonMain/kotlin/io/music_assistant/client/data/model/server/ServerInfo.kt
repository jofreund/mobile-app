package io.music_assistant.client.data.model.server

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Highest server schema_version this client is built and tested against.
 *
 * Only one thing reads this now: the terminal `CLIENT_INCOMPATIBLE` check in
 * `SchemaVersionWarningViewModel`, which fires when the server's
 * `min_supported_schema_version` has climbed past this value — i.e. when the server has
 * genuinely dropped support for what this client speaks. That is the case worth an alert,
 * and it fails safe: a stale value here only ever warns too eagerly, never too late.
 *
 * It used to also drive a dismissible "the server is newer than the app" alert, which meant
 * every server release raised it until this constant was chased upstream — the bump to 54 was
 * exactly that, and upstream was at 59 by the time it landed. Upstream removed that alert
 * (music-assistant/mobile-app@c9e03d71) and so has this fork; see the enum in
 * `SchemaVersionWarningViewModel`.
 *
 * The capabilities that actually needed gating are gated on their own constants: the
 * recommendations rows/items split (39, `RECOMMENDATION_ITEMS_SCHEMA` in `MediaItemRepository`)
 * and server-side localization of API strings (32, `SERVER_LOCALIZATION_SCHEMA`). The 2.10
 * queue-item `stream_metadata` payload is simply optional in the DTO. Nothing here gates above
 * 39, so this stays a tested-against marker rather than a capability claim.
 *
 * 59 (2026-08-27): tracks upstream's verified-compatible value.
 */
const val LOCAL_SCHEMA_VERSION = 59

@Serializable
data class ServerInfo(
    @SerialName("server_id") var serverId: String,
    @SerialName("server_version") var serverVersion: String? = null,
    @SerialName("schema_version") var schemaVersion: Int? = null,
    @SerialName("min_supported_schema_version") var minSupportedSchemaVersion: Int? = null,
    /** Deprecated in favour of [internalUrl]. Old servers send only this field. */
    @SerialName("base_url") var baseUrl: String? = null,
    @SerialName("name") var name: String? = null,
    @SerialName("internal_url") var internalUrl: String? = null,
    @SerialName("external_url") var externalUrl: String? = null,
    @SerialName("has_remote_access") var hasRemoteAccess: Boolean = false,
    // @SerialName("homeassistant_addon") var homeassistantAddon: Boolean? = null,
    // @SerialName("onboard_done") var onboardDone: Boolean? = null
)
