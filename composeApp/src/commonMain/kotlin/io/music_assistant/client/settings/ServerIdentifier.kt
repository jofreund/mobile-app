package io.music_assistant.client.settings

import io.music_assistant.client.utils.SessionState

/**
 * Canonical token-store key for the server a session is connected to —
 * "direct:ws(s)://host:port" or "webrtc:remoteId", matching
 * [SettingsRepository.getDirectServerIdentifier] / [SettingsRepository.getWebRTCServerIdentifier].
 *
 * Shared by [io.music_assistant.client.auth.AuthenticationManager] (token lifecycle) and
 * `LocalPlayerController` (Sendspin proxy auth): upstream keys tokens by the server's own
 * `server_id`, this fork keys them by how the connection was made, so anything ported from
 * upstream must resolve the token through this and never through `serverInfo.serverId`.
 */
fun SettingsRepository.getServerIdentifier(sessionState: SessionState): String? {
    return when (sessionState) {
        is SessionState.Connected -> getServerIdentifier(sessionState)
        else -> null
    }
}

fun SettingsRepository.getServerIdentifier(sessionState: SessionState.Connected): String {
    return when (sessionState) {
        is SessionState.Connected.Direct -> this.getDirectServerIdentifier(
            sessionState.connectionInfo.host,
            sessionState.connectionInfo.port,
            sessionState.connectionInfo.isTls,
        )

        is SessionState.Connected.WebRTC -> this.getWebRTCServerIdentifier(sessionState.remoteId.rawId)
    }
}
