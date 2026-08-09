package io.music_assistant.client.ui.compose.common.items

import io.music_assistant.client.data.model.client.QueueOption

sealed class ItemAction(val kind: Kind) {
    enum class Kind { PLAYBACK, OTHER }

    data class Play(val queueOption: QueueOption) : ItemAction(Kind.PLAYBACK)
    data object PlayFromHere : ItemAction(Kind.PLAYBACK)
    data object StartRadio : ItemAction(Kind.PLAYBACK)

    data object AddToLibrary : ItemAction(Kind.OTHER)
    data object RemoveFromLibrary : ItemAction(Kind.OTHER)
    data object Favorite : ItemAction(Kind.OTHER)
    data object Unfavorite : ItemAction(Kind.OTHER)

    data object AddToPlaylist : ItemAction(Kind.OTHER)
    data object RemoveFromPlaylist : ItemAction(Kind.OTHER)

    data object MarkPlayed : ItemAction(Kind.OTHER)
    data object MarkUnplayed : ItemAction(Kind.OTHER)

    data object Customize : ItemAction(Kind.PLAYBACK)
}
