package io.music_assistant.client.data.model.client

data class Player(
    val id: String,
    val name: String,
    val provider: String,
    val type: PlayerType,
    /** Server-provided Material Design Icons name (e.g. "speaker"); null when absent. */
    val icon: String? = null,
    val shouldBeShown: Boolean,
    val canSetVolume: Boolean,
    val canPower: Boolean,
    val isPowered: Boolean,
    val volumeLevel: Float?,
    val volumeControl: String?,
    val volumeMuted: Boolean,
    val canMute: Boolean,
    val queueId: String?,
    val isPlaying: Boolean,
    val isAnnouncing: Boolean,
    val canGroupWith: List<String>?,
    val groupMembers: Set<String>?,
    val staticGroupMembers: Set<String>?,
    val activeGroup: String?,
    val syncedTo: String?,
    val groupVolume: Float?,
    val groupVolumeMuted: Boolean,
    val currentMedia: PlayerMedia?,
    /** Unix (UTC) timestamp in seconds at which the sleep timer stops playback. */
    val sleepTimerExpiresAt: Double? = null,
    /**
     * The player's own position in [currentMedia], as its provider last reported it. Read only
     * through [externalElapsedSec]: for Music Assistant playback the queue is the position.
     */
    val elapsedTime: Double? = null,
    /** Unix epoch seconds (UTC) at which [elapsedTime] was reported. */
    val elapsedTimeLastUpdated: Double? = null,
    /** The server lists `seek` among the player's features: it can seek in media of its own. */
    val supportsSeek: Boolean = false,
) {
    val isPoweredOff: Boolean get() = canPower && !isPowered

    /**
     * True when the player reports media that Music Assistant is not streaming to it — a
     * HomePod playing Apple Music, a Home Assistant media player fed by another app. Such a
     * player's MA queue is idle: its elapsed time is stale, and the only position that means
     * anything is the player's own.
     *
     * Media the server plays from a queue is stamped with the queue's item id, and names the
     * queue as its source; a queue carries its player's id, so a source id equal to [id] is
     * this player's own queue. (Pre-rename servers named the queue in `queue_id` instead, and
     * sent no source id at all — hence all three.) Media carrying none of them belongs to
     * another source.
     */
    val hasExternalMedia: Boolean
        get() = currentMedia != null &&
            currentMedia.queueItemId == null &&
            currentMedia.queueId == null &&
            currentMedia.sourceId != id

    /**
     * Position in [currentMedia] for a player with [hasExternalMedia], projected to
     * [nowEpochSec]; null for Music Assistant playback or when the provider reports none.
     *
     * Providers that mirror another system report the position sparsely (Home Assistant
     * forwards `media_position` only when the entity re-reports it), so a playing player is
     * advanced by the wall time since the report, capped at the media duration. A paused
     * player sits exactly where it was reported.
     */
    fun externalElapsedSec(nowEpochSec: Double): Double? {
        if (!hasExternalMedia) return null
        val reported = elapsedTime ?: return null
        val lastUpdated = elapsedTimeLastUpdated
        val advanced = if (isPlaying && lastUpdated != null) {
            reported + (nowEpochSec - lastUpdated).coerceAtLeast(0.0)
        } else {
            reported
        }
        return currentMedia?.duration?.let { advanced.coerceAtMost(it) } ?: advanced
    }

    /**
     * Whether a seek sent for this player can land. On a Music Assistant queue the queue seeks,
     * whatever the player itself can do. Off it (see [hasExternalMedia]) the server hands the
     * seek to the player, and refuses it unless the player declares [supportsSeek] — so the
     * scrubber goes inert rather than offering a drag that snaps back.
     */
    val canSeek: Boolean get() = !hasExternalMedia || supportsSeek

    val isGroup = type == PlayerType.GROUP
    val isGrouped = !isGroup && groupMembers?.isNotEmpty() == true

    val suffix = when {
        isGroup -> " (${groupMembers?.size ?: 0})"
        isGrouped && (groupMembers?.size ?: 0) > 1 -> " +${groupMembers?.size?.minus(1)}"
        else -> null
    }

    val nameAndSuffix: String = name + (suffix?.let { " $it" } ?: "")

    val providerType = provider.substringBefore("--")

    val currentVolume = if (groupMembers?.isNotEmpty() == true) groupVolume else volumeLevel
    val currentMuteState = if (groupMembers?.isNotEmpty() == true) groupVolumeMuted else volumeMuted

    val isVolumeSliderAccessible = (isGroup || canSetVolume) && currentVolume != null && !isPoweredOff

    val canPlay = when {
        isGroup -> groupMembers?.isNotEmpty() == true
        else -> true
    }

    fun asChildBindFor(other: Player): PlayerData.ChildBind? {
        if (id == other.id) return null
        val isAlreadyGrouped = other.groupMembers?.contains(id) == true
        val canGroupByProvider = other.canGroupWith?.contains(providerType) == true
        val canGroupById = other.canGroupWith?.contains(id) == true
        if (!isAlreadyGrouped && !canGroupByProvider && !canGroupById) return null
        return PlayerData.ChildBind(
            id = id,
            parentId = other.id,
            name = name,
            volume = volumeLevel,
            volumeSliderAccessible = isVolumeSliderAccessible,
            isMuted = currentMuteState.takeIf { canMute },
            isBound = other.groupMembers?.contains(id) == true,
            isManageable = other.staticGroupMembers?.contains(id) != true,
        )
    }

    fun asParentBind(): PlayerData.ParentBind {
        return PlayerData.ParentBind(
            id = id,
            name = name,
            isPlaying = isPlaying,
            isGroup = isGroup,
        )
    }
}

/**
 * The id of the queue [this] player is actually playing from, which is not always its own.
 *
 * A player synced to another, or taken over by a group, plays that one's queue: the server
 * redirects every playback command there and reports the position against it, while the
 * player's own queue sits idle holding whatever it last had. Binding a grouped player to its
 * own queue is how a book on it showed 0:00 however far in it really was — and why picking a
 * chapter there looked like it did nothing, the seek having moved a queue nothing was
 * watching.
 *
 * Mirrors the server's own `get_active_queue`: sync leader first, then active group, then the
 * player's own active source. Bounded against a cycle in the reported parents, which would
 * otherwise not terminate.
 */
fun Player.activeQueueId(allPlayers: List<Player>): String? {
    var current = this
    repeat(MAX_PLAYER_PARENT_HOPS) {
        val parentId = current.syncedTo?.takeIf { it != current.id }
            ?: current.activeGroup?.takeIf { it != current.id }
            ?: return current.queueId
        val parent = allPlayers.firstOrNull { it.id == parentId } ?: return current.queueId
        current = parent
    }
    return current.queueId
}

/**
 * How far to follow "this player is really playing that one's queue" before giving up.
 * Groups nest at most a couple of levels; beyond this the reported parents form a cycle.
 */
private const val MAX_PLAYER_PARENT_HOPS = 4
