package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.QueueInfo
import io.music_assistant.client.data.model.client.RepeatMode
import io.music_assistant.client.ui.compose.common.action.PlayerAction

/**
 * Maps a platform remote-command string (Control Center / lock screen) to the [PlayerAction] to
 * dispatch. Toggle commands read their current state from [queueInfo], defaulting to off when no
 * queue exists. Returns null for unrecognized commands and malformed seek payloads.
 *
 * Lifted out of `LocalPlayerController` unchanged. It was never local-player-specific — it maps
 * a string vocabulary that `NowPlayingCoordinator` emits to actions any player can take — and it
 * had to outlive that file, since system-media controls now drive the *selected* player rather
 * than the phone's own. Its tests (`RemoteCommandMappingTest`) came along untouched.
 */
internal fun remoteCommandToPlayerAction(command: String, queueInfo: QueueInfo?): PlayerAction? = when {
    command == "play" -> PlayerAction.Play
    command == "pause" -> PlayerAction.Pause
    command == "toggle_play_pause" -> PlayerAction.TogglePlayPause
    command == "next" -> PlayerAction.Next
    command == "previous" -> PlayerAction.Previous
    command == "toggle_shuffle" ->
        PlayerAction.ToggleShuffle(current = queueInfo?.shuffleEnabled == true)
    command == "toggle_repeat" ->
        PlayerAction.ToggleRepeatMode(current = queueInfo?.repeatMode ?: RepeatMode.OFF)
    command.startsWith("seek:") ->
        command.removePrefix("seek:").toDoubleOrNull()?.let { PlayerAction.SeekTo(it.toLong()) }
    command.startsWith("seek_by:") ->
        command.removePrefix("seek_by:").toLongOrNull()?.let { PlayerAction.SeekBy(it) }
    else -> null
}
