// Position update intervals and debounce values inline-documented at use site.
@file:Suppress("MagicNumber")

package io.music_assistant.client.data

import co.touchlab.kermit.Logger
import io.music_assistant.client.api.APICommands
import io.music_assistant.client.api.Request
import io.music_assistant.client.api.ServiceClient
import io.music_assistant.client.api.isAccepted
import io.music_assistant.client.data.MainDataSource.Companion.resolveSelectedPlayerId
import io.music_assistant.client.data.factory.MediaItemFactory
import io.music_assistant.client.data.factory.PlayerFactory
import io.music_assistant.client.data.factory.QueueFactory
import io.music_assistant.client.data.model.client.ImageType
import io.music_assistant.client.data.model.client.Player
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.Queue
import io.music_assistant.client.data.model.client.QueueInfo
import io.music_assistant.client.data.model.client.isBefore
import io.music_assistant.client.data.model.client.items.AppMediaItem
import io.music_assistant.client.data.model.client.items.LongFormSeekDefaults
import io.music_assistant.client.data.model.client.items.Track
import io.music_assistant.client.data.model.client.items.image
import io.music_assistant.client.data.model.server.DspConfig
import io.music_assistant.client.data.model.server.DspConfigPreset
import io.music_assistant.client.data.model.server.ServerPlayer
import io.music_assistant.client.data.model.server.ServerQueue
import io.music_assistant.client.data.model.server.ServerQueueItem
import io.music_assistant.client.data.model.server.ServerUser
import io.music_assistant.client.data.model.server.events.MediaItemAddedEvent
import io.music_assistant.client.data.model.server.events.MediaItemDeletedEvent
import io.music_assistant.client.data.model.server.events.MediaItemPlayedData
import io.music_assistant.client.data.model.server.events.MediaItemPlayedEvent
import io.music_assistant.client.data.model.server.events.MediaItemUpdatedEvent
import io.music_assistant.client.data.model.server.events.PlayerAddedEvent
import io.music_assistant.client.data.model.server.events.PlayerRemovedEvent
import io.music_assistant.client.data.model.server.events.PlayerUpdatedEvent
import io.music_assistant.client.data.model.server.events.QueueAddedEvent
import io.music_assistant.client.data.model.server.events.QueueItemsUpdatedEvent
import io.music_assistant.client.data.model.server.events.QueueTimeUpdatedEvent
import io.music_assistant.client.data.model.server.events.QueueUpdatedEvent
import io.music_assistant.client.player.MediaPlayerController
import io.music_assistant.client.player.sendspin.model.GoodbyeReason
import io.music_assistant.client.settings.SettingsRepository
import io.music_assistant.client.ui.compose.common.DataState
import io.music_assistant.client.ui.compose.common.StaleReason
import io.music_assistant.client.ui.compose.common.action.PlayerAction
import io.music_assistant.client.ui.compose.common.action.QueueAction
import io.music_assistant.client.utils.AuthProcessState
import io.music_assistant.client.utils.DataConnectionState
import io.music_assistant.client.utils.SessionState
import io.music_assistant.client.utils.currentTimeMillis
import io.music_assistant.client.utils.resultAs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.IO
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.CoroutineContext
import kotlin.math.abs

/** Preserve newer event/optimistic state when a delayed full snapshot arrives. */
internal fun mergeFullQueueSnapshot(
    retained: List<QueueInfo>,
    incoming: List<QueueInfo>,
): List<QueueInfo> {
    val retainedById = retained.associateBy { it.id }
    return incoming.map { candidate ->
        val current = retainedById[candidate.id]
        if (current != null && candidate.isBefore(current)) current else candidate
    }
}

@OptIn(FlowPreview::class)
class MainDataSource(
    private val settings: SettingsRepository,
    val apiClient: ServiceClient,
    private val mediaPlayerController: MediaPlayerController,
    private val localPlayerController: LocalPlayerController,
    private val playerRequestFactory: PlayerRequestFactory,
    private val resumePointResolver: ResumePointResolver,
    /**
     * Single source of truth for live elapsed-time per queue. Server events
     * write anchors here, play/pause transitions snapshot the interpolated
     * position. All consumers (in-app slider, MediaSession writes for AA +
     * notification, iOS NowPlaying, audiobook chapter logic) read from this
     * tracker — synchronously via [PlayerPositionTracker.effectiveSec] or as
     * a smoothly-ticking flow via [PlayerPositionTracker.observe]. Shared with
     * [PlayerRequestFactory] (and [LocalPlayerController] through it) via DI.
     */
    val positionTracker: PlayerPositionTracker,
    private val mediaItemFactory: MediaItemFactory,
    private val playerFactory: PlayerFactory,
    private val queueFactory: QueueFactory,
    /** Server-synced user preferences, refreshed from `auth/me` and shared by all surfaces. */
    val userPreferences: UserPreferences,
) : CoroutineScope {
    private val log = Logger.withTag("MainDataSource")

    /** Combined inputs for a [MainDataSource] player-data rebuild. */
    private data class PlayerBuildInputs(
        val players: DataState<List<Player>>,
        val queues: List<QueueInfo>,
        val localData: PlayerData?,
        val favoriteOverrides: Map<String, Boolean>,
        val playbackOverrides: Map<String, PlaybackOverride>,
    )

    /** Local (Sendspin) player lifecycle, state and commands live in the controller. */
    val sendspinState = localPlayerController.sendspinState

    /** Seconds of audio buffered ahead of the local playhead (buffered-progress indicator). */
    val localBufferedSeconds = localPlayerController.bufferedSeconds

    /**
     * Optimistic play-state for one player. A fresh instance per write on purpose: the timeout
     * in [setPlaybackOverride] compares by identity, so a newer toggle for the same player
     * invalidates the older revert instead of being cleared by it.
     */
    private class PlaybackOverride(val isPlaying: Boolean)

    private val supervisorJob = SupervisorJob()
    override val coroutineContext: CoroutineContext = supervisorJob + Dispatchers.IO

    private val _serverPlayers = MutableStateFlow<DataState<List<Player>>>(DataState.Loading())
    private val _queueInfos = MutableStateFlow<List<QueueInfo>>(emptyList())

    /**
     * Authoritative favorite state per track, keyed by [favKey]. The server's
     * queue payload reports a stale `favorite` for the now-playing track (it
     * lags behind, indefinitely, after a toggle), so it cannot be trusted.
     * This overlay is written optimistically on user toggle and reconciled by
     * the reliable [MediaItemUpdatedEvent], then re-applied on every rebuild in
     * [buildPlayerDataList] so queue updates can't clobber it.
     */
    private val _favoriteOverrides = MutableStateFlow<Map<String, Boolean>>(emptyMap())

    /**
     * Optimistic play-state per player id, so the play/pause icon (and the position tracker's
     * ticking, which mirrors `player.isPlaying`) flips on the tap instead of after the full
     * tap → RPC → player-reacts → `player_updated` round trip — a second or more on slow
     * players. Written on transport dispatch in [applyOptimisticFeedback], re-applied on every
     * rebuild in [buildPlayerDataList], cleared when a [PlayerUpdatedEvent] confirms the target
     * state, rolled back on send failure, and reverted by a timeout if the server never
     * confirms (an external change mid-flight also just waits out the timeout).
     */
    private val _playbackOverrides = MutableStateFlow<Map<String, PlaybackOverride>>(emptyMap())

    private val _players =
        combine(_serverPlayers, settings.playersSorting) { playersState, sortedIds ->
            when (playersState) {
                is DataState.Error,
                is DataState.Loading,
                is DataState.NoData,
                    -> playersState

                is DataState.Data -> {
                    val players = playersState.data
                    DataState.Data(
                        sortedIds?.let {
                            players.sortedBy { player ->
                                sortedIds.indexOf(player.id).takeIf { it >= 0 }
                                    ?: Int.MAX_VALUE
                            }
                        } ?: players.sortedBy { player -> player.name },
                    )
                }

                is DataState.Stale -> {
                    // Preserve stale state with sorted data
                    val players = playersState.data
                    DataState.Stale(
                        data = sortedIds?.let {
                            players.sortedBy { player ->
                                sortedIds.indexOf(player.id).takeIf { it >= 0 }
                                    ?: Int.MAX_VALUE
                            }
                        } ?: players.sortedBy { player -> player.name },
                        disconnectedAt = playersState.disconnectedAt,
                        reason = playersState.reason,
                    )
                }
            }
        }.stateIn(
            scope = this,
            started = SharingStarted.Eagerly,
            initialValue = DataState.Loading(),
        )

    private val _playersData = MutableStateFlow<DataState<List<PlayerData>>>(DataState.Loading())
    val playersData = _playersData.asStateFlow()

    // Overlay the optimistic favorite override onto the local player, exactly as
    // [buildPlayerDataList] does for `_playersData`. Without this, a consumer sourcing
    // [localPlayer] directly (not `_playersData`) never sees the override and the heart
    // only flips after a real server update.
    val localPlayer: StateFlow<PlayerData?> =
        combine(localPlayerController.localPlayerData, _favoriteOverrides) { data, overrides ->
            data?.let { applyFavoriteOverride(it, overrides) }
        }.stateIn(this, SharingStarted.Eagerly, null)

    /** Local player paired with the chapter every system-media channel presents. */
    private val localPlayerPresentation =
        localPlayer.withPresentationChapter(userPreferences, positionTracker) { it }

    /**
     * Local system-media metadata; chapter presentation re-emits at boundaries
     * because no server event announces the duration/album change.
     */
    val nowPlayingTrack: StateFlow<NowPlayingTrack?> =
        localPlayerPresentation
            .map {
                buildNowPlayingTrack(
                    playerData = it.value,
                    currentChapter = it.chapter,
                    chapterNavigationEnabled = userPreferences.isChapterProgressEnabled,
                )
            }
            .distinctUntilChanged()
            .stateIn(this, SharingStarted.Eagerly, null)

    /**
     * Local transport anchors carry content identity for cross-channel correlation.
     * Track and transport have no ordering guarantee; no-track states remain null.
     */
    val nowPlayingTransport: StateFlow<NowPlayingTransport?> =
        localPlayerPresentation
            .map {
                buildNowPlayingTransport(
                    playerData = it.value,
                    positionTracker = positionTracker,
                    currentChapter = it.chapter,
                )
            }
            .distinctUntilChanged(NowPlayingChannelChangeDetection::sameTransport)
            .stateIn(this, SharingStarted.Eagerly, null)

    /** Queue modes and their shared availability gate for system-media controls. */
    val nowPlayingModes: StateFlow<NowPlayingModes?> =
        localPlayer
            .map(::buildNowPlayingModes)
            .distinctUntilChanged()
            .stateIn(this, SharingStarted.Eagerly, null)

    val isAnythingPlaying =
        playersData
            .mapNotNull { it as? DataState.Data<List<PlayerData>> }
            .map { it.data.any { data -> data.player.isPlaying } }
            .stateIn(this, SharingStarted.Eagerly, false)
    val doesAnythingHavePlayableItem =
        playersData
            .mapNotNull { it as? DataState.Data<List<PlayerData>> }
            .map { it.data.any { data -> data.queueInfo?.currentItem != null } }
            .stateIn(this, SharingStarted.Eagerly, false)

    /**
     * Persisted user choice. Restored from settings on startup and written
     * only by [selectPlayer]; the persistence collector in [init] mirrors
     * non-null values into [SettingsRepository.lastSelectedPlayerId] for
     * the next app launch.
     */
    private val _userSelectedPlayerId =
        MutableStateFlow(settings.lastSelectedPlayerId.value)

    /**
     * Effective selection consumed by the rest of the data source and UI.
     * Derived from the current player list and the user choice via
     * [resolveSelectedPlayerId] — pure function, re-evaluated on every
     * input change. No state machine pushes a fallback into the upstream
     * flow; the resolver computes it on the fly.
     */
    private val _selectedPlayerId: StateFlow<String?> =
        combine(
            _playersData,
            _userSelectedPlayerId,
        ) { playersDataState, user ->
            val visibleIds = (playersDataState as? DataState.Data)
                ?.data?.map { it.playerId }
                .orEmpty()
            resolveSelectedPlayerId(
                visiblePlayerIds = visibleIds,
                userChoice = user,
            )
        }.stateIn(this, SharingStarted.Eagerly, settings.lastSelectedPlayerId.value)

    val selectedPlayerIndex = combine(_playersData, _selectedPlayerId) { listState, selectedId ->
        selectedId?.let { id ->
            (listState as? DataState.Data)?.data?.indexOfFirst { it.playerId == id }
                ?.takeIf { it >= 0 }
        }
    }.stateIn(this, SharingStarted.Eagerly, null)

    val selectedPlayer: PlayerData?
        get() = selectedPlayerIndex.value?.let { selectedIndex ->
            (_playersData.value as? DataState.Data)?.data?.getOrNull(selectedIndex)
        }

    /**
     * Native mini player's bridged view of the player list + selection — see
     * [buildPlayerBarState].
     *
     * The `distinctUntilChanged` is load-bearing, not hygiene: without it a queue-time event
     * roughly once a second pushes an otherwise-identical projection all the way through to
     * SwiftUI. See [playerBarStatesEquivalentIgnoringElapsed] for why ignoring `elapsedTime`
     * specifically is the safe way to do that.
     */
    /**
     * Reused across rebuilds so a queue-time tick doesn't re-map every queue item just for the
     * comparison below to throw the result away — see [QueueProjectionCache]. Owned here because
     * it must outlive a single projection; confined to the single collector below.
     *
     * Declared *before* [playerBarState] deliberately: `stateIn(…, Eagerly, …)` launches its
     * collector during construction, so a cache declared after it could still be uninitialized
     * when the first emission arrives.
     */
    private val queueProjectionCache = QueueProjectionCache()

    val playerBarState: StateFlow<PlayerBarState> =
        combine(playersData, selectedPlayerIndex, ::Pair)
            // Only the selected player is ever on screen with a scrubber, so it is the only
            // one whose chapter has to be resolved — and the only one worth holding a boundary
            // timer for. `withPresentationChapter` re-emits at each boundary, which is the sole
            // trigger there is: no server event announces that the chapter changed.
            .withPresentationChapter(userPreferences, positionTracker) { (data, index) ->
                index?.let { (data as? DataState.Data)?.data?.getOrNull(it) }
            }
            .map { presentation ->
                val (data, index) = presentation.value
                buildPlayerBarState(
                    playersDataState = data,
                    selectedIndex = index,
                    queueCache = queueProjectionCache,
                    presentationChapter = presentation.chapter?.let {
                        ChapterBarItem(
                            name = it.displayName,
                            startSec = it.start,
                            durationSec = it.duration,
                        )
                    },
                )
            }
            .distinctUntilChanged(::playerBarStatesEquivalentIgnoringElapsed)
            .stateIn(this, SharingStarted.Eagerly, PlayerBarState.Loading)

    /**
     * The Live Activity's view of the selected player — see [LiveActivitySnapshot]. Declared
     * after [playerBarState] because it is derived from it, and the eager `stateIn` collector
     * needs that flow to exist.
     */
    val liveActivityState: StateFlow<LiveActivitySnapshot?> =
        playerBarState
            .map(::liveActivitySnapshot)
            .distinctUntilChanged()
            .stateIn(this, SharingStarted.Eagerly, null)

    // --- Canonical media-session "now playing" source ---
    // Single source of truth for what the MediaSession / notification presents,
    // consumed by the Android SharedMediaSessionManager (the sole session writer)
    // and its transport callback. Players eligible for the session are those that
    // can play and have a current queue item.
    private val sessionPlayers: StateFlow<List<PlayerData>> =
        playersData
            .mapNotNull { (it as? DataState.Data)?.data }
            .map { list -> list.filter { it.player.canPlay && it.queueInfo?.currentItem != null } }
            .stateIn(this, SharingStarted.Eagerly, emptyList())

    val sessionMultiplePlayers: StateFlow<Boolean> =
        sessionPlayers.map { it.size > 1 }.stateIn(this, SharingStarted.Eagerly, false)

    /**
     * The player the media session currently presents: the user-selected one when
     * it is session-eligible, else the first playing player, else the first eligible.
     * Unifies notification + in-app selection on [selectedPlayer] — no separate index.
     */
    val nowPlayingPlayer: StateFlow<PlayerData?> =
        combine(sessionPlayers, _selectedPlayerId) { session, selectedId ->
            session.firstOrNull { it.playerId == selectedId }
                ?: session.firstOrNull { it.player.isPlaying }
                ?: session.firstOrNull()
        }.stateIn(this, SharingStarted.Eagerly, null)

    /** Cycle the session to the next eligible player (notification "switch player" action). */
    fun switchSessionPlayer() {
        val list = sessionPlayers.value
        if (list.size <= 1) return
        val currentId = nowPlayingPlayer.value?.playerId
        val idx = list.indexOfFirst { it.playerId == currentId }.takeIf { it >= 0 } ?: 0
        selectPlayer(list[(idx + 1) % list.size].player)
    }

    /** Point the session at the first playing eligible player. Returns false if none plays. */
    fun focusPlayingSessionPlayer(): Boolean {
        val playing = sessionPlayers.value.firstOrNull { it.player.isPlaying } ?: return false
        selectPlayer(playing.player)
        return true
    }

    private var watchJob: Job? = null
    private var updateJob: Job? = null

    init {
        mediaPlayerController.setLongFormSeekIntervals(
            LongFormSeekDefaults.BACK_SECONDS,
            LongFormSeekDefaults.FORWARD_SECONDS,
        )

        // Re-fetch server players/queues after Sendspin registers (state → Ready).
        launch {
            localPlayerController.needsServerRefresh.collect { updatePlayersAndQueues() }
        }

        // Mirror optimistic-bump stamps into `_queueInfos` so the staleness gate sees them.
        launch {
            localPlayerController.optimisticQueueChanges.collect { queueInfo ->
                _queueInfos.update { value ->
                    if (value.any { it.id == queueInfo.id }) {
                        value.map { if (it.id == queueInfo.id) queueInfo else it }
                    } else {
                        value + queueInfo
                    }
                }
            }
        }

        // Watch for Sendspin settings changes: the enable/disable toggle acts
        // immediately, no reconnect needed.
        launch {
            settings.sendspinEnabled.collect { enabled ->
                if (apiClient.sessionState.value is SessionState.Connected) {
                    if (enabled) {
                        localPlayerController.start()
                        // Inject synthetic player immediately so UI reflects the change
                        // before Sendspin fully connects and server confirms the player
                        localPlayerController.onInitialPlayersReceived(hasLocalPlayer = false)
                    } else {
                        localPlayerController.stop(GoodbyeReason.UserRequest)
                        // User turned Sendspin off — the local player is gone for good.
                        // stop() no longer resets it (transient teardowns must preserve
                        // a queued resume), so clear it explicitly here.
                        localPlayerController.clearState()
                    }
                }
            }
        }

        // Arms `hasActivePlayback` so backgrounding mid-playback doesn't tear down
        // Sendspin (goodbye=shutdown → audio stops, server cold-resumes). Driven off
        // logical `isPlaying`, which survives the transient transport blip — unlike
        // the Sendspin sync state.
        launch {
            localPlayer
                .map { it?.player?.isPlaying == true }
                .distinctUntilChanged()
                .collect { if (it) apiClient.onPlaybackActive() else apiClient.onPlaybackInactive() }
        }

        // Mirror play state into the tracker. setPlaying snapshots the
        // interpolated position on transitions so pause/resume don't fold
        // pause-duration into the next forward step. Cheap dedup inside.
        launch {
            playersData
                .mapNotNull { (it as? DataState.Data)?.data }
                .collect { list ->
                    list.forEach { pd ->
                        // An externally fed player has no queue to key on; its entry is
                        // keyed by player id (see anchorExternalPosition).
                        val key = pd.queueInfo?.id
                            ?: pd.playerId.takeIf { pd.player.hasExternalMedia }
                            ?: return@forEach
                        positionTracker.setPlaying(key, pd.player.isPlaying)
                    }
                }
        }

        launch {
            combine(
                _players,
                _queueInfos,
                localPlayerController.localPlayerData,
                _favoriteOverrides,
                _playbackOverrides,
            ) { players, queues, localData, favOverrides, playbackOverrides ->
                PlayerBuildInputs(players, queues, localData, favOverrides, playbackOverrides)
            }
                // Conflate rather than debounce: a burst of server events still collapses to one
                // rebuild (whatever arrived while the previous build ran), but nothing waits for a
                // quiet period first. This used to be `debounce(50 ms)`, and because the optimistic
                // play-state and favorite overrides are inputs to this same combine, every tap paid
                // that 50 ms before its feedback could reach the screen.
                .conflate()
                .collect { input ->
                    _playersData.update { oldValues ->
                        when (input.players) {
                            is DataState.Error -> DataState.Error()
                            is DataState.Loading -> DataState.Loading()
                            is DataState.NoData -> DataState.NoData()
                            is DataState.Data -> DataState.Data(
                                buildPlayerDataList(
                                    input.players.data,
                                    input.queues,
                                    input.localData,
                                    input.favoriteOverrides,
                                    input.playbackOverrides,
                                    oldValues,
                                ),
                            )

                            is DataState.Stale -> DataState.Stale(
                                data = buildPlayerDataList(
                                    input.players.data,
                                    input.queues,
                                    input.localData,
                                    input.favoriteOverrides,
                                    input.playbackOverrides,
                                    oldValues,
                                ),
                                disconnectedAt = input.players.disconnectedAt,
                                reason = input.players.reason,
                            )
                        }
                    }
                }
        }
        launch {
            apiClient.sessionState.collect { sessionState ->
                log.i { "SessionState changed: ${sessionState::class.simpleName}" }

                when (sessionState) {
                    is SessionState.Connected -> {
                        // Start watching events (cancel old job if exists to avoid duplicates)
                        watchJob?.cancel()
                        watchJob = watchApiEvents()

                        if (sessionState.dataConnectionState is DataConnectionState.Authenticated) {
                            log.i {
                                val from = when (val current = _serverPlayers.value) {
                                    is DataState.Stale -> "Stale(${current.reason})"
                                    else -> current::class.simpleName
                                }
                                "Authenticated — resyncing from $from"
                            }
                            // Keep whatever we already hold on screen while the re-sync below
                            // runs: the fetches replace it in place, so the player list never
                            // blinks through "Loading players" on a reconnect.
                            _serverPlayers.update { preserveThroughResync(it) }
                            // Unconditional, and deliberately outside any branch on how we got
                            // here. Every arrival at Connected/Authenticated follows a gap in the
                            // event stream, and no server replays what was missed: `player_updated`
                            // and `queue_updated` fire once, at the moment the now-playing item
                            // changes, and only `queue_time_updated` keeps arriving afterwards —
                            // which carries an elapsed time and nothing else.
                            //
                            // So a gap that straddles a track change leaves the cached player
                            // showing the *previous* song, with a ticking playhead, until the
                            // next track change happens to land. Backgrounding the app is the
                            // easy way to reproduce that: tear-down on background, reconnect on
                            // foreground, and a track boundary in between.
                            //
                            // This used to be skipped for Stale(RECONNECTING) on the grounds that
                            // a brief disconnection leaves data "still fresh". Length was never
                            // the relevant question — a one-second gap can straddle a track
                            // boundary just as well as a one-minute one — and the blink that
                            // reasoning was protecting against is handled by the line above.
                            updatePlayersAndQueues()
                            updateUserPreferences()
                            // Sendspin (re)init: WebRTC sendspin auth is inherited from the
                            // data channel itself, not JSON-RPC auth state, so it must be
                            // re-driven on every arrival at Authenticated. The factory
                            // detects channel freshness from the DataChannelWrapper
                            // identity, so a still-healthy client is left alone.
                            launch { localPlayerController.start() }
                            // Replay any commands queued while disconnected.
                            localPlayerController.drainCommandQueue()
                        } else {
                            // Not authenticated yet
                            val connState = sessionState.dataConnectionState
                            val isTerminalAuthFailure =
                                connState is DataConnectionState.AwaitingAuth &&
                                        (
                                                connState.authProcessState is AuthProcessState.LoggedOut ||
                                                        connState.authProcessState is AuthProcessState.Failed
                                                )

                            if (isTerminalAuthFailure) {
                                // Auth permanently failed — stop everything
                                localPlayerController.stop(GoodbyeReason.Shutdown)
                                clearAllData()
                            } else {
                                // Transient: AwaitingServerInfo or auth in progress.
                                // Keep sendspin alive — it is reinitialized when auth completes.
                                // Preserve stale data so reconnection recovery works.
                                if (_serverPlayers.value !is DataState.Stale) {
                                    clearAllData()
                                }
                            }
                            updateJob?.cancel()
                            updateJob = null
                            watchJob?.cancel()
                            watchJob = null
                        }
                    }

                    is SessionState.Reconnecting -> {
                        when (val currentState = _serverPlayers.value) {
                            is DataState.Data -> {
                                // Transition to Stale(RECONNECTING) - preserve data
                                log.i { "Data → Stale(RECONNECTING): preserving ${(currentState.data as? List<*>)?.size ?: 0} players" }
                                _serverPlayers.update {
                                    DataState.Stale(
                                        data = currentState.data,
                                        disconnectedAt = currentTimeMillis(),
                                        reason = StaleReason.RECONNECTING,
                                    )
                                }
                            }

                            is DataState.Stale -> {
                                // Already stale - update reason if needed, preserve original disconnectedAt
                                if (currentState.reason != StaleReason.RECONNECTING) {
                                    log.i { "Stale(${currentState.reason}) → Stale(RECONNECTING)" }
                                    _serverPlayers.update {
                                        DataState.Stale(
                                            data = currentState.data,
                                            disconnectedAt = currentState.disconnectedAt,  // KEEP ORIGINAL
                                            reason = StaleReason.RECONNECTING,
                                        )
                                    }
                                }
                                // else: already Stale(RECONNECTING), do nothing
                            }

                            is DataState.Loading, is DataState.NoData, is DataState.Error -> {
                                // No data to preserve - stay in current state
                                log.i { "Reconnecting with no data to preserve (state: ${currentState::class.simpleName})" }
                            }
                        }

                        // KEEP: jobs running, position tracking active. watchJob will be idle
                        // (no events from a disconnected WebSocket); updateJob keeps running for
                        // position calculations.
                    }

                    SessionState.Connecting -> {
                        log.i { "Connecting - stopping Sendspin" }
                        localPlayerController.stop(GoodbyeReason.Restart)
                        updateJob?.cancel()
                        updateJob = null
                        watchJob?.cancel()
                        watchJob = null
                        // Preserve stale data (e.g. reconnecting from backgrounded state)
                        // so the player list stays visible instead of showing "Loading players"
                        when (val current = _serverPlayers.value) {
                            is DataState.Data -> _serverPlayers.update {
                                DataState.Stale(
                                    current.data,
                                    currentTimeMillis(),
                                    StaleReason.RECONNECTING,
                                )
                            }

                            is DataState.Stale -> {} // Already stale, keep as is
                            else -> _serverPlayers.update { DataState.Loading() }
                        }
                    }

                    is SessionState.Disconnected -> {
                        when (sessionState) {
                            SessionState.Disconnected.ByUser -> {
                                // Intentional logout - clear everything
                                log.i { "Disconnected by user - clearing all data" }
                                localPlayerController.stop(GoodbyeReason.UserRequest)
                                clearAllData()
                                updateJob?.cancel()
                                updateJob = null
                                watchJob?.cancel()
                                watchJob = null
                            }

                            is SessionState.Disconnected.Error -> {
                                // Persistent error after max reconnect attempts
                                when (val currentState = _serverPlayers.value) {
                                    is DataState.Data, is DataState.Stale -> {
                                        // Preserve data as Stale(PERSISTENT_ERROR)
                                        val data = when (currentState) {
                                            is DataState.Data -> currentState.data
                                            is DataState.Stale -> currentState.data
                                        }
                                        val originalDisconnectedAt =
                                            (currentState as? DataState.Stale)?.disconnectedAt
                                                ?: currentTimeMillis()

                                        val staleCount = (data as? List<*>)?.size ?: 0
                                        log.w { "Persistent connection error - preserving $staleCount players as stale" }
                                        _serverPlayers.update {
                                            DataState.Stale(
                                                data = data,
                                                disconnectedAt = originalDisconnectedAt,  // Preserve original
                                                reason = StaleReason.PERSISTENT_ERROR,
                                            )
                                        }

                                        // Stop Sendspin (can't stream without connection)
                                        localPlayerController.stop(GoodbyeReason.Restart)
                                    }

                                    is DataState.Loading, is DataState.NoData, is DataState.Error -> {
                                        // No data to preserve - transition to NoData
                                        log.w { "Persistent error with no data to preserve" }
                                        _serverPlayers.update { DataState.NoData() }
                                        _queueInfos.update { emptyList() }
                                    }
                                }

                                // Cancel jobs (no point running without connection)
                                updateJob?.cancel()
                                updateJob = null
                                watchJob?.cancel()
                                watchJob = null
                            }

                            SessionState.Disconnected.Backgrounded -> {
                                // App backgrounded — preserve data for instant foreground reconnect
                                when (val currentState = _serverPlayers.value) {
                                    is DataState.Data -> {
                                        log.i { "Backgrounded — preserving ${currentState.data.size} players as Stale(RECONNECTING)" }
                                        _serverPlayers.update {
                                            DataState.Stale(
                                                data = currentState.data,
                                                disconnectedAt = currentTimeMillis(),
                                                reason = StaleReason.RECONNECTING,
                                            )
                                        }
                                    }

                                    is DataState.Stale -> {
                                        log.i { "Backgrounded — already stale, keeping data" }
                                    }

                                    else -> {
                                        log.i { "Backgrounded with no data to preserve" }
                                    }
                                }

                                localPlayerController.stop(GoodbyeReason.Restart)
                                updateJob?.cancel()
                                updateJob = null
                                watchJob?.cancel()
                                watchJob = null
                            }

                            SessionState.Disconnected.Initial, SessionState.Disconnected.NoServerData -> {
                                // App startup or no server configured - clear all
                                log.i { "Disconnected (${sessionState::class.simpleName}) - clearing data" }
                                localPlayerController.stop(GoodbyeReason.Shutdown)
                                clearAllData()
                                updateJob?.cancel()
                                updateJob = null
                                watchJob?.cancel()
                                watchJob = null
                            }
                        }
                    }
                }
            }
        }
        launch {
            // Persist user-driven selection so it survives app restarts.
            // Only [selectPlayer] writes the upstream flow, so this captures
            // explicit picks. Nulls are filtered out because clearing the
            // persisted value isn't a product requirement and rarely the
            // user's intent.
            _userSelectedPlayerId
                .filterNotNull()
                .distinctUntilChanged()
                .collect { settings.setLastSelectedPlayerId(it) }
        }
        launch {
            // Fetch queue items for the selected player. Keyed on
            // (playerId, queueInfo.id) rather than the selection *index* so it
            // also re-fires when the selected player's queueInfo arrives late, long after its
            // row (and index) first appears. An index-keyed trigger never re-emits for a
            // same-slot player, leaving that player's items unfetched on cold start.
            // sendRequest's gate handles "not ready"; a pre-check would only add
            // a TOCTOU race.
            combine(playersData, _selectedPlayerId) { pd, id ->
                (pd as? DataState.Data)?.data?.firstOrNull { it.playerId == id }
            }
                .mapNotNull { it?.takeIf { pd -> pd.queueInfo != null } }
                .distinctUntilChangedBy { it.playerId to it.queueInfo?.id }
                .collect { refreshPlayerQueueItems(it, trigger = QueueItemsTrigger.QUEUE_INFO_ARRIVED) }
        }
    }

    /**
     * Build the merged player data list for [_playersData].
     * Local player uses repository state (single source of truth); others built from server data.
     */
    private fun buildPlayerDataList(
        allPlayers: List<Player>,
        queues: List<QueueInfo>,
        localData: PlayerData?,
        favoriteOverrides: Map<String, Boolean>,
        playbackOverrides: Map<String, PlaybackOverride>,
        oldValues: DataState<List<PlayerData>>,
    ): List<PlayerData> {
        val localPlayerId = settings.sendspinEffectivePlayerId.value
        val playerDataList = allPlayers
            .map { player ->
                val isLocal = player.id == localPlayerId
                val parent =
                    (player.activeGroup ?: player.syncedTo)
                        ?.let { parentId -> allPlayers.firstOrNull { it.id == parentId } }
                        ?.asParentBind()
                val groupChildren =
                    // No children for the local player; a player that is itself part of
                    // a group exposes no children of its own either.
                    if (isLocal || parent != null) {
                        emptyList()
                    } else {
                        allPlayers.mapNotNull { it.asChildBindFor(player) }
                    }
                if (isLocal && localData != null) {
                    // The controller is source of truth for the local player; surface the
                    // latest server-anchored `elapsedTime` from `_queueInfos` so the slider
                    // re-anchors on `QueueTimeUpdatedEvent` (which writes only to
                    // `_queueInfos`, not the controller).
                    val trackedElapsed = queues.find {
                        it.id == player.queueId || it.id == localPlayerId
                    }?.elapsedTime
                    val withPosition = trackedElapsed?.let {
                        (localData.queue as? DataState.Data)?.let { qd ->
                            localData.copy(
                                queue = DataState.Data(
                                    qd.data.copy(info = qd.data.info.copy(elapsedTime = it)),
                                ),
                                parentBind = parent,
                            )
                        }
                    } ?: localData
                    // Preserve loaded queue items from previous state
                    (oldValues as? DataState.Data)?.data
                        ?.firstOrNull { it.player.id == player.id }
                        ?.updateFrom(withPosition) ?: withPosition
                } else {
                    val newData = PlayerData(
                        player = player,
                        queue = queues.find { it.id == player.queueId }
                            ?.let { queueInfo ->
                                DataState.Data(
                                    Queue(info = queueInfo, items = DataState.NoData()),
                                )
                            } ?: DataState.NoData(),
                        parentBind = parent,
                        childrenBinds = groupChildren,
                        isLocal = isLocal,
                    )
                    // Preserve loaded queue items from the previous state.
                    (oldValues as? DataState.Data)?.data
                        ?.firstOrNull { it.player.id == player.id }
                        ?.updateFrom(newData) ?: newData
                }
            }

        // Inject the synthetic local player when the server list doesn't carry it yet.
        val withLocal =
            if (localData != null && playerDataList.none { it.playerId == localPlayerId }) {
                listOf(localData) + playerDataList
            } else {
                playerDataList
            }

        // Fill any null now-playing artwork from the queue track, then re-apply favorite and
        // playback overrides last so a stale server payload can't win. The patches are
        // independent (currentMedia vs queue.currentItem.track.favorite vs player.isPlaying),
        // so order is free.
        return withLocal
            .map { applyNowPlayingArtwork(it) }
            .let { list ->
                if (favoriteOverrides.isEmpty()) {
                    list
                } else {
                    list.map { applyFavoriteOverride(it, favoriteOverrides) }
                }
            }
            .let { list ->
                if (playbackOverrides.isEmpty()) {
                    list
                } else {
                    list.map { applyPlaybackOverride(it, playbackOverrides) }
                }
            }
    }

    /**
     * Fill a null now-playing [PlayerMedia.imageUrl] from the queue's current-item track
     * artwork. The server sometimes omits the image on the player media payload while the
     * track still carries metadata images; without this the player cover, compact bar and
     * media notification go blank even though the queue row shows art. No-op for the local
     * player (its imageUrl is already set from the track in `LocalPlayerController`).
     */
    private fun applyNowPlayingArtwork(playerData: PlayerData): PlayerData {
        val media = playerData.player.currentMedia ?: return playerData
        if (media.imageUrl != null) return playerData
        val currentItem = (playerData.queue as? DataState.Data)?.data?.info?.currentItem
            ?: return playerData
        if (currentItem.id != media.queueItemId) return playerData // guard track transitions
        val url = currentItem.track.image(ImageType.THUMB)?.url ?: return playerData
        return playerData.copy(
            player = playerData.player.copy(currentMedia = media.copy(imageUrl = url)),
        )
    }

    /** Stable per-track key for [_favoriteOverrides]. */
    private fun favKey(item: AppMediaItem): String =
        item.uri ?: "${item.provider}:${item.itemId}"

    /**
     * Optimistically set (or clear, when [favorite] is null) the favorite flag
     * for [item] in [_favoriteOverrides]. Triggers a [_playersData] rebuild via
     * the combine so the now-playing heart updates immediately.
     */
    fun setFavoriteOverride(item: AppMediaItem, favorite: Boolean?) {
        _favoriteOverrides.update { current ->
            if (favorite == null) current - favKey(item) else current + (favKey(item) to favorite)
        }
    }

    /**
     * Canonical favorite toggle for [item], shared by the in-app player heart and the
     * media-session (Android Auto) favorite action. Optimistically flips the override
     * (the server's queue payload reports a stale `favorite`), fires the add/remove
     * request, and rolls the override back if the server rejects it. Reconciled later
     * by [MediaItemUpdatedEvent].
     */
    fun toggleFavorite(item: AppMediaItem) {
        launch {
            val newFavorite = item.favorite != true
            val result = if (newFavorite) {
                setFavoriteOverride(item, true)
                // `referenceUri` rather than the raw `uri` — see [AppMediaItem.referenceUri].
                apiClient.sendRequest(Request.Library.addFavorite(item.referenceUri))
            } else {
                setFavoriteOverride(item, false)
                apiClient.sendRequest(
                    Request.Library.removeFavorite(item.itemId, item.mediaType),
                )
            }
            // `isAccepted`, not `onFailure`: a server rejection still arrives as a successful
            // Result carrying an error payload, and it too must roll the optimistic flip back —
            // no `MediaItemUpdatedEvent` will ever come to reconcile a refused write.
            if (!result.isAccepted) {
                log.e(result.exceptionOrNull()) {
                    "Favorite toggle to $newFavorite rejected for ${item.itemId}: " +
                        (result.getOrNull()?.errorDetails ?: "transport failure")
                }
                setFavoriteOverride(item, item.favorite)
            }
        }
    }

    /** Overrides the player's play-state from [overrides] — see [_playbackOverrides]. */
    private fun applyPlaybackOverride(
        playerData: PlayerData,
        overrides: Map<String, PlaybackOverride>,
    ): PlayerData {
        val override = overrides[playerData.playerId] ?: return playerData
        if (playerData.player.isPlaying == override.isPlaying) return playerData
        return playerData.copy(
            player = playerData.player.copy(isPlaying = override.isPlaying),
        )
    }

    /**
     * Write an optimistic play-state for [playerId] and schedule its revert: if no
     * [PlayerUpdatedEvent] confirms the target within [PLAYBACK_OVERRIDE_TIMEOUT_MS], the
     * override is dropped and the UI falls back to server truth. Identity-compared so a newer
     * override for the same player is never cleared by an older override's timeout.
     */
    private fun setPlaybackOverride(playerId: String, isPlaying: Boolean) {
        val override = PlaybackOverride(isPlaying)
        _playbackOverrides.update { it + (playerId to override) }
        launch {
            delay(PLAYBACK_OVERRIDE_TIMEOUT_MS)
            _playbackOverrides.update { current ->
                if (current[playerId] === override) {
                    log.w { "Playback override for $playerId never confirmed; reverting" }
                    current - playerId
                } else {
                    current
                }
            }
        }
    }

    private fun clearPlaybackOverride(playerId: String) {
        _playbackOverrides.update { current ->
            if (playerId in current) current - playerId else current
        }
    }

    /** Overrides the now-playing track's favorite flag from [overrides]. */
    private fun applyFavoriteOverride(
        playerData: PlayerData,
        overrides: Map<String, Boolean>,
    ): PlayerData {
        val queueData = playerData.queue as? DataState.Data ?: return playerData
        val currentItem = queueData.data.info.currentItem ?: return playerData
        val track = currentItem.track
        val item = track as? AppMediaItem ?: return playerData
        val override = overrides[favKey(item)] ?: return playerData
        if (track.favorite == override) return playerData
        return playerData.copy(
            queue = DataState.Data(
                queueData.data.copy(
                    info = queueData.data.info.copy(
                        currentItem = currentItem.copy(track = track.withFavorite(override)),
                    ),
                ),
            ),
        )
    }

    /**
     * Clear all cached data.
     */
    private fun clearAllData() {
        log.i { "Clearing all cached data" }
        _serverPlayers.update { DataState.NoData() }
        _queueInfos.update { emptyList() }
        _playbackOverrides.update { emptyMap() }
        positionTracker.clear()
        userPreferences.clear()
        localPlayerController.clearState()
    }

    /**
     * Forward a queue event to the local player controller when it belongs to
     * the local player — matched by the effective player id, or by the queue id
     * the server currently reports for that player.
     */
    private fun forwardLocalQueueUpdate(data: QueueInfo) {
        val localPlayerId = settings.sendspinEffectivePlayerId.value
        if (data.id == localPlayerId ||
            (_serverPlayers.value as? DataState.Data)?.data
                ?.find { it.id == localPlayerId }?.queueId == data.id
        ) {
            localPlayerController.onServerQueueUpdate(data)
        }
    }

    /**
     * Refreshes preferences from `auth/me`; a failed fetch keeps the current values.
     *
     * Re-read on every authenticated connect rather than once per launch: the web frontend
     * owns these toggles, so they can change while this client is away, and there is no
     * event announcing it.
     */
    private fun updateUserPreferences() {
        launch {
            apiClient.sendRequest(Request(APICommands.AUTH_ME))
                .resultAs<ServerUser>()
                ?.let { userPreferences.update(it.preferences) }
        }
    }

    suspend fun getDspConfig(playerId: String): DspConfig? =
        apiClient.sendRequest(Request.Dsp.getPlayerConfig(playerId))
            .getOrNull()?.resultAs<DspConfig>()

    suspend fun saveDspConfig(playerId: String, config: DspConfig): DspConfig? {
        return apiClient.sendRequest(Request.Dsp.savePlayerConfig(playerId, config))
            .getOrNull()?.resultAs<DspConfig>()
    }

    suspend fun getDspPresets(): List<DspConfigPreset> =
        apiClient.sendRequest(Request.Dsp.getPresets())
            .getOrNull()?.resultAs<List<DspConfigPreset>>() ?: emptyList()

    fun selectPlayer(player: Player) {
        // User-driven selection (UI player picker). Writes through
        // [_userSelectedPlayerId] so the choice persists; the persistence
        // launch in [init] mirrors it into [SettingsRepository] for the next
        // app launch.
        _userSelectedPlayerId.update { player.id }
    }

    /** By-id overload for the native mini player's pager-settle callback — same effect as
     * [selectPlayer], just without requiring a full [Player] the caller may not have handy. */
    fun selectPlayer(playerId: String) {
        _userSelectedPlayerId.update { playerId }
    }

    /** `null` if this event is older than what `_queueInfos` already holds for the same id. */
    private fun QueueInfo.takeIfNotStale(label: String): QueueInfo? {
        val existing = _queueInfos.value.find { it.id == id } ?: return this
        if (isBefore(existing)) {
            log.d {
                "Dropping stale $label for $id: $elapsedTimeLastUpdated < ${existing.elapsedTimeLastUpdated}"
            }
            return null
        }
        return this
    }

    fun playerAction(playerId: String, action: PlayerAction) {
        launch {
            when (action) {
                PlayerAction.TogglePlayPause -> {
                    apiClient.sendRequest(
                        Request.Player.simpleCommand(
                            playerId = playerId,
                            command = "play_pause",
                        ),
                    )
                }

                PlayerAction.Play -> {
                    apiClient.sendRequest(
                        Request.Player.simpleCommand(
                            playerId = playerId,
                            command = "play",
                        ),
                    )
                }

                PlayerAction.Pause -> {
                    apiClient.sendRequest(
                        Request.Player.simpleCommand(
                            playerId = playerId,
                            command = "pause",
                        ),
                    )
                }

                PlayerAction.Next -> {
                    apiClient.sendRequest(
                        Request.Player.simpleCommand(playerId = playerId, command = "next"),
                    )
                }

                PlayerAction.Previous -> {
                    apiClient.sendRequest(
                        Request.Player.simpleCommand(
                            playerId = playerId,
                            command = "previous",
                        ),
                    )
                }

                is PlayerAction.SeekTo -> {
                    apiClient.sendRequest(
                        Request.Player.seek(
                            queueId = playerId,
                            position = action.position,
                        ),
                    )
                }

                PlayerAction.VolumeDown -> apiClient.sendRequest(
                    Request.Player.simpleCommand(
                        playerId = playerId,
                        command = "volume_down",
                    ),
                )

                PlayerAction.VolumeUp -> apiClient.sendRequest(
                    Request.Player.simpleCommand(
                        playerId = playerId,
                        command = "volume_up",
                    ),
                )

                is PlayerAction.ToggleMute -> apiClient.sendRequest(
                    Request.Player.setMute(playerId = playerId, !action.isMutedNow),
                )

                is PlayerAction.VolumeSet -> apiClient.sendRequest(
                    Request.Player.setVolume(
                        playerId = playerId,
                        volumeLevel = action.level,
                    ),
                )

                PlayerAction.GroupVolumeDown -> apiClient.sendRequest(
                    Request.Player.simpleCommand(
                        playerId = playerId,
                        command = "group_volume_down",
                    ),
                )

                PlayerAction.GroupVolumeUp -> apiClient.sendRequest(
                    Request.Player.simpleCommand(
                        playerId = playerId,
                        command = "group_volume_up",
                    ),
                )

                is PlayerAction.GroupToggleMute -> apiClient.sendRequest(
                    Request.Player.setGroupMute(playerId = playerId, !action.isMutedNow),
                )

                is PlayerAction.GroupVolumeSet -> apiClient.sendRequest(
                    Request.Player.setGroupVolume(
                        playerId = playerId,
                        volumeLevel = action.level,
                    ),
                )

                is PlayerAction.GroupManage -> apiClient.sendRequest(
                    Request.Player.setGroupMembers(
                        playerId = playerId,
                        playersToAdd = action.toAdd,
                        playersToRemove = action.toRemove,
                    ),
                )

                // This overload hand-duplicates a subset of what the PlayerData one below
                // resolves through PlayerRequestFactory, so shuffle/repeat/power/speed and
                // friends land here and go nowhere. Callers that only hold a player id (the
                // native group settings sheet, CarPlay) rely on the cases above; anything else
                // reaching this branch is a wiring mistake that used to vanish without trace.
                else -> log.w { "playerAction(playerId) has no branch for $action — dropped" }
            }
        }
    }

    fun playerAction(data: PlayerData, action: PlayerAction) {
        // The local player owns its optimistic update + offline-queue + send path.
        if (data.isLocal) {
            localPlayerController.handleLocalCommand(data, action)
            return
        }
        val resolved = playerRequestFactory.resolve(data, action)
        applyOptimisticFeedback(data, resolved)
        launch { sendResolvedPlayerAction(data, action, withResumePoint(data, resolved)) }
    }

    /**
     * [playerAction], but suspends until the request has actually left the process (or failed).
     * Exists for the Live Activity's play/pause intent: that runs in an app process the system
     * may suspend the moment the intent returns, so fire-and-forget would race suspension.
     * Returns whether the transport accepted the send — a server *rejection* still counts as
     * sent; the optimistic override's timeout revert covers that case.
     */
    suspend fun playerActionAwaitingSend(data: PlayerData, action: PlayerAction): Boolean {
        // Local branch mirrors [playerAction]: the controller owns optimistic state and
        // offline-queueing, and its send path is fire-and-forget by design — the offline
        // queue (not the caller) covers the suspension race the awaiting variant exists for.
        if (data.isLocal) {
            localPlayerController.handleLocalCommand(data, action)
            return true
        }
        val resolved = playerRequestFactory.resolve(data, action)
        applyOptimisticFeedback(data, resolved)
        return sendResolvedPlayerAction(data, action, withResumePoint(data, resolved))
    }

    /**
     * Lets [ResumePointResolver] relocate a resume of a paused audiobook/episode to the
     * server's resume point. The play half of the feedback is already showing from
     * [applyOptimisticFeedback]; a relocated resume additionally anchors at its position.
     */
    private suspend fun withResumePoint(data: PlayerData, resolved: PlayerAction): PlayerAction =
        resumePointResolver.resolve(data, resolved).also { synced ->
            if (synced is PlayerAction.PlayFrom) applyOptimisticFeedback(data, synced)
        }

    private suspend fun sendResolvedPlayerAction(
        data: PlayerData,
        action: PlayerAction,
        resolved: PlayerAction,
    ): Boolean {
        val request = playerRequestFactory.buildRequest(data, resolved) ?: return false
        val result = apiClient.sendRequest(request)
        if (result.isFailure) {
            clearPlaybackOverride(data.playerId)
            log.e(
                result.exceptionOrNull(),
            ) { "Failed to send player action request for ${data.player.name}: $action" }
            return false
        }
        restorePauseAfterSeek(data, resolved)
        return true
    }

    /**
     * Reflect a transport action in local state before the server confirms it, so the tap has
     * visible effect immediately instead of after the full round trip (see [_playbackOverrides]):
     *
     *  - Play/pause flips [Player.isPlaying] via the override map — which also freezes/resumes
     *    the position tracker's ticking through the mirror collector in `init`.
     *  - Next/Previous drops the position anchor to 0 (the track that follows starts there,
     *    and a `previous` that restarts the current track does too).
     *  - SeekTo anchors at the target — audiobook chapter skips arrive here already resolved
     *    into their SeekTo, so they anchor at the chapter start rather than 0.
     *  - PlayFrom is both: playing, anchored at the server's resume point.
     *
     * Anchors need no rollback bookkeeping: the next server anchor overwrites them, and while
     * playing one arrives about every second.
     */
    private fun applyOptimisticFeedback(data: PlayerData, resolved: PlayerAction) {
        when (resolved) {
            PlayerAction.TogglePlayPause ->
                setPlaybackOverride(data.playerId, !data.player.isPlaying)

            PlayerAction.Play -> setPlaybackOverride(data.playerId, true)
            PlayerAction.Pause -> setPlaybackOverride(data.playerId, false)
            PlayerAction.Next, PlayerAction.Previous ->
                data.queueInfo?.id?.let { positionTracker.setAnchor(it, elapsedSec = 0.0) }

            is PlayerAction.SeekTo ->
                data.queueInfo?.id?.let {
                    positionTracker.setAnchor(it, elapsedSec = resolved.position.toDouble())
                }

            is PlayerAction.PlayFrom -> {
                setPlaybackOverride(data.playerId, true)
                data.queueInfo?.id?.let {
                    positionTracker.setAnchor(it, elapsedSec = resolved.position.toDouble())
                }
            }

            else -> Unit
        }
    }

    /**
     * Server-anchored position from a queue payload. Skipped while the queue's player plays
     * media from another source (see [Player.hasExternalMedia]): that queue is idle and its
     * `elapsed_time` is wherever MA last left it, while the tracker entry under the same id —
     * MA gives a queue its player's id — holds the player's own position from
     * [anchorExternalPosition]. Letting the stale queue value through would drag the playhead
     * back onto a track that is not playing.
     */
    private fun anchorQueuePosition(queueInfo: QueueInfo) {
        val elapsed = queueInfo.elapsedTime ?: return
        if (queueOwnerPlaysExternalMedia(queueInfo.id)) return
        val player = (_serverPlayers.value as? DataState.Data)
            ?.data?.find { it.queueId == queueInfo.id }
        positionTracker.setAnchor(
            queueId = queueInfo.id,
            elapsedSec = elapsed,
            isPlaying = player?.isPlaying,
            durationSec = queueInfo.currentItem?.track?.duration,
            speed = queueInfo.playbackSpeed,
        )
    }

    /**
     * Whether the player owning [queueId] currently plays media from another source. An
     * externally fed player's `queueId` points at that source rather than its MA queue, so the
     * owner is found by id (MA gives a queue its player's id) when the queue lookup misses.
     */
    private fun queueOwnerPlaysExternalMedia(queueId: String): Boolean {
        val players = (_serverPlayers.value as? DataState.Data)?.data ?: return false
        val owner = players.find { it.queueId == queueId } ?: players.find { it.id == queueId }
        return owner?.hasExternalMedia == true
    }

    /**
     * The player's own position, for a player fed by another source (see
     * [Player.hasExternalMedia]); a no-op for MA playback. Keyed by player id: MA gives a
     * queue its player's id, so this is the entry the native player already observes for it,
     * and the one [anchorQueuePosition] leaves alone while the other source plays. Once MA
     * plays through the queue again, its events overwrite this.
     */
    private fun anchorExternalPosition(player: Player) {
        val elapsed = player.externalElapsedSec(currentTimeMillis() / 1000.0) ?: return
        positionTracker.setAnchor(
            queueId = player.id,
            elapsedSec = elapsed,
            isPlaying = player.isPlaying,
            durationSec = player.currentMedia?.duration,
            speed = 1.0,
        )
    }

    /**
     * Another player is moving the resume point of an audiobook/episode that a paused queue
     * here is showing: move that queue's displayed position along, so the slider shows where
     * a resume will pick up (see [ResumePointResolver]).
     *
     * Anchor only. `_queueInfos.elapsedTime` stays the server's view of the queue, which is
     * what the resolver compares the resume point against on the next play — and what the
     * next queue event overwrites this anchor with anyway, so this is a live courtesy while
     * connected, not a second source of truth.
     */
    private fun followResumePoint(played: MediaItemPlayedData) {
        if (played.secondsPlayed <= 0.0) return
        val players = (playersData.value as? DataState.Data)?.data ?: return
        players.queuesFollowing(played).forEach { queueId ->
            positionTracker.setAnchor(queueId = queueId, elapsedSec = played.secondsPlayed)
        }
    }

    /**
     * Puts a paused player back to paused after a seek.
     *
     * Seeking starts playback server-side: `players/cmd/seek` becomes a `play_index` at the new
     * position, so moving the playhead resumes as a side effect. A listener who scrubs a paused
     * track is repositioning it, not asking to hear it, and having it start is both surprising
     * and — on a shared speaker — occasionally embarrassing.
     *
     * **Waits for the seek to take hold first, and this is load-bearing.** The seek's own answer
     * only says the command was accepted: server-side it becomes `play_index` at the new
     * position, which flushes and restarts the stream. A pause arriving during that setup tore it
     * down before it applied, and the queue went back to reporting the position it had before —
     * a seek on a paused player that visibly reverted a few seconds later.
     *
     * So this watches the queue's own elapsed time until it reflects the target, then pauses.
     * Bounded, because a server that never applies the seek must not leave a player that was
     * paused sitting there playing.
     *
     * `isPlaying` is the snapshot from when the action was dispatched — deliberately, since the
     * question is what the player was doing when the user grabbed the bar.
     */
    private suspend fun restorePauseAfterSeek(data: PlayerData, resolved: PlayerAction) {
        if (resolved !is PlayerAction.SeekTo || data.player.isPlaying) return

        val target = resolved.position.toDouble()
        val applied = withTimeoutOrNull(SEEK_SETTLE_TIMEOUT_MS) {
            playersData
                .mapNotNull { state ->
                    (state as? DataState.Data)?.data
                        ?.firstOrNull { it.playerId == data.playerId }
                        ?.queueInfo
                        ?.elapsedTime
                }
                .first { elapsed -> abs(elapsed - target) <= SEEK_SETTLE_TOLERANCE_SECONDS }
        }
        if (applied == null) {
            log.w { "Seek to ${target}s never took hold for ${data.player.name}; pausing anyway" }
        }

        val request = playerRequestFactory.buildRequest(data, PlayerAction.Pause) ?: return
        val result = apiClient.sendRequest(request)
        if (result.isFailure) {
            log.e(
                result.exceptionOrNull(),
            ) { "Failed to restore pause after seek for ${data.player.name}" }
        }
    }

    /**
     * Starts a server-side sleep timer of [seconds] on [playerId].
     *
     * Deliberately not a [PlayerAction]: the timer lives on the server for every player,
     * the local (Sendspin) one included — the server stops it over the normal protocol —
     * so this must never take the local branch of [playerAction]. No optimistic state:
     * the server calls `update_state()`, so the confirming `PlayerUpdatedEvent` carries
     * the new expiry back within the same round trip.
     */
    fun setSleepTimer(playerId: String, seconds: Int) {
        launch {
            apiClient.sendRequest(Request.Player.setSleepTimer(playerId, seconds))
                .onFailure { log.e(it) { "Failed to set sleep timer for $playerId" } }
        }
    }

    /** Clears the server-side sleep timer on [playerId]. See [setSleepTimer]. */
    fun clearSleepTimer(playerId: String) {
        launch {
            apiClient.sendRequest(Request.Player.clearSleepTimer(playerId))
                .onFailure { log.e(it) { "Failed to clear sleep timer for $playerId" } }
        }
    }

    fun queueAction(action: QueueAction) {
        launch {
            when (action) {
                is QueueAction.PlayQueueItem -> {
                    apiClient.sendRequest(
                        Request.Queue.playIndex(
                            queueId = action.queueId,
                            queueItemId = action.queueItemId,
                        ),
                    )
                }

                is QueueAction.ClearQueue -> {
                    apiClient.sendRequest(
                        Request.Queue.clear(
                            queueId = action.queueId,
                        ),
                    )
                }

                is QueueAction.RemoveItems -> {
                    action.items.forEach {
                        apiClient.sendRequest(
                            Request.Queue.removeItem(
                                queueId = action.queueId,
                                queueItemId = it,
                            ),
                        )
                    }
                }

                is QueueAction.MoveItem -> {
                    (action.to - action.from)
                        .takeIf { it != 0 }
                        ?.let { shift ->
                            val result = apiClient.sendRequest(
                                Request.Queue.moveItem(
                                    queueId = action.queueId,
                                    queueItemId = action.queueItemId,
                                    positionShift = shift,
                                ),
                            )
                            // The server refuses to move an item it has already played or
                            // buffered, and this whole function used to discard every result —
                            // so a rejected move looked identical to an applied one from the
                            // client's side. Log it instead of guessing. `isAccepted`, not
                            // `isSuccess`: a rejection still arrives as a successful Result,
                            // carrying an error payload.
                            if (result.isAccepted) {
                                log.d {
                                    "Queue move accepted: item=${action.queueItemId} " +
                                        "${action.from}->${action.to} (pos_shift=$shift)"
                                }
                            } else {
                                log.e(result.exceptionOrNull()) {
                                    "Queue move rejected: item=${action.queueItemId} " +
                                        "${action.from}->${action.to} (pos_shift=$shift) " +
                                        "details=${result.getOrNull()?.errorDetails}"
                                }
                            }
                        }
                }

                is QueueAction.Transfer -> {
                    apiClient.sendRequest(
                        Request.Queue.transfer(
                            sourceId = action.sourceId,
                            targetId = action.targetId,
                            autoplay = action.autoplay,
                        ),
                    )
                }
            }
        }
    }

    fun onPlayersSortChanged(newSort: List<String>) = settings.updatePlayersSorting(newSort)

    private fun watchApiEvents() =
        launch {
            apiClient.events
                .collect { event ->
                    when (event) {
                        is PlayerAddedEvent -> {
                            playerFactory.create(event.data)
                                .takeIf { it.shouldBeShown }
                                ?.let { newPlayer ->
                                    _serverPlayers.update { oldState ->
                                        when (oldState) {
                                            is DataState.Data -> {
                                                val players = oldState.data
                                                DataState.Data(
                                                    if (players.none { it.id == newPlayer.id }) {
                                                        players + newPlayer
                                                    } else {
                                                        // Player already exists, just update it
                                                        players.map { if (it.id == newPlayer.id) newPlayer else it }
                                                    },
                                                )
                                            }

                                            else -> oldState
                                        }
                                    }
                                    anchorExternalPosition(newPlayer)
                                }
                        }

                        is PlayerRemovedEvent -> {
                            val playerId =
                                event.objectId ?: event.data.takeIf { it.isNotEmpty() }
                            if (playerId != null) {
                                _serverPlayers.update { oldState ->
                                    when (oldState) {
                                        is DataState.Data -> {
                                            DataState.Data(
                                                oldState.data.filter { it.id != playerId },
                                            )
                                        }

                                        else -> oldState
                                    }
                                }
                            }
                        }

                        is PlayerUpdatedEvent -> {
                            val data = playerFactory.create(event.data)
                            // Forward to the local player controller if this is the local player
                            if (data.id == settings.sendspinEffectivePlayerId.value) {
                                localPlayerController.onServerPlayerUpdate(data)
                            }
                            // Server truth caught up with an optimistic play-state — stop
                            // overriding. A mismatching event (emitted before our command
                            // executed) keeps the override until it confirms or times out.
                            _playbackOverrides.value[data.id]?.let { override ->
                                if (override.isPlaying == data.isPlaying) {
                                    clearPlaybackOverride(data.id)
                                }
                            }
                            _serverPlayers.update { oldState ->
                                when (oldState) {
                                    is DataState.Data -> {
                                        val players = oldState.data
                                        DataState.Data(
                                            if (data.shouldBeShown) {
                                                if (players.any { it.id == data.id }) {
                                                    players.map { if (it.id == data.id) data else it }
                                                } else {
                                                    players + data // Player just became visible
                                                }
                                            } else {
                                                players.filter { it.id != data.id }
                                            },
                                        )
                                    }

                                    else -> oldState
                                }
                            }
                            anchorExternalPosition(data)
                        }

                        is QueueAddedEvent -> {
                            // Server announces a queue (typically when a new
                            // player connects and MA registers its queue).
                            val data = queueFactory.create(event.data).takeIfNotStale("QueueAdded")
                                ?: return@collect

                            forwardLocalQueueUpdate(data)

                            // Upsert: replace if present, append if new.
                            _queueInfos.update { value ->
                                if (value.any { it.id == data.id }) {
                                    value.map { if (it.id == data.id) data else it }
                                } else {
                                    value + data
                                }
                            }
                            anchorQueuePosition(data)
                        }

                        is QueueUpdatedEvent -> {
                            val data =
                                queueFactory.create(event.data).takeIfNotStale("QueueUpdated")
                                    ?: return@collect

                            forwardLocalQueueUpdate(data)

                            _queueInfos.update { value ->
                                value.map {
                                    if (it.id == data.id) data else it
                                }
                            }
                            anchorQueuePosition(data)
                        }

                        is QueueItemsUpdatedEvent -> {
                            val data = queueFactory.create(event.data)

                            // The items list changed — always refetch it. The
                            // staleness gate guards the playhead anchor only;
                            // shuffle/reorder don't advance elapsed time (and the
                            // optimistic bump raises the bar further), so gating
                            // the refetch on it silently drops legitimate reorders
                            // like shuffle. The refetch pulls authoritative items
                            // from the server, so it can't snap the list backward
                            // even on a replayed event.
                            val fresh = data.takeIfNotStale("QueueItemsUpdated")
                            fresh?.let { freshData ->
                                _queueInfos.update { value ->
                                    value.map {
                                        if (it.id == freshData.id) freshData else it
                                    }
                                }
                                anchorQueuePosition(freshData)
                            }
                            (playersData.value as? DataState.Data)?.data?.firstOrNull {
                                it.queueId == data.id
                            }?.let {
                                refreshPlayerQueueItems(it, fresh, QueueItemsTrigger.QUEUE_EVENT)
                            }
                        }

                        is QueueTimeUpdatedEvent -> {
                            // Not staleness-gated: payload has no server-side
                            // `last_updated` to compare against. Relies on
                            // in-order WebSocket delivery instead.
                            _queueInfos.update { value ->
                                value.map {
                                    if (it.id == event.objectId) it.copy(elapsedTime = event.data) else it
                                }
                            }
                            event.objectId?.let { queueId ->
                                if (queueOwnerPlaysExternalMedia(queueId)) return@let
                                positionTracker.setAnchor(
                                    queueId = queueId,
                                    elapsedSec = event.data,
                                )
                            }
                        }

                        is MediaItemPlayedEvent -> {
                            // Not a position source for playing queues — those anchor on
                            // `QueueTimeUpdatedEvent` above. Paused queues showing the same
                            // audiobook/episode follow the resume point it reports.
                            followResumePoint(event.data)
                        }

                        is MediaItemUpdatedEvent -> {
                            (mediaItemFactory.create(event.data) as? Track)
                                ?.let {
                                    // Reliable server truth — reconcile the optimistic
                                    // overlay so it survives the stale queue payload.
                                    it.favorite?.let { fav -> setFavoriteOverride(it, fav) }
                                    updateMediaTrackInfo(it)
                                }
                        }

                        is MediaItemAddedEvent -> {
                            (mediaItemFactory.create(event.data) as? Track)
                                ?.let { updateMediaTrackInfo(it) }
                        }

                        is MediaItemDeletedEvent -> {
                            (mediaItemFactory.create(event.data) as? Track)
                                ?.let { deletedTrack ->
                                    _playersData.update { currentState ->
                                        when (currentState) {
                                            is DataState.Error,
                                            is DataState.Loading,
                                            is DataState.NoData,
                                            is DataState.Stale,
                                                -> currentState

                                            is DataState.Data -> DataState.Data(
                                                currentState.data.map { playerData ->
                                                    playerData.queueItems?.let { items ->
                                                        val updatedItems = items.filter {
                                                            (it.track as? AppMediaItem)
                                                                ?.hasAnyMappingFrom(deletedTrack) != true
                                                        }
                                                        playerData.copy(
                                                            queue = (playerData.queue as? DataState.Data)?.let { queueData ->
                                                                DataState.Data(
                                                                    queueData.data.copy(
                                                                        items = DataState.Data(
                                                                            updatedItems,
                                                                        ),
                                                                    ),
                                                                )
                                                            } ?: playerData.queue,
                                                        )
                                                    } ?: playerData
                                                },
                                            )
                                        }
                                    }
                                }
                        }

                        else -> log.i { "Unhandled event: $event" }
                    }
                }
        }

    private fun updateMediaTrackInfo(newTrack: Track) {
        _playersData.update { currentState ->
            when (currentState) {
                is DataState.Error,
                is DataState.Loading,
                is DataState.NoData,
                is DataState.Stale,
                    -> currentState

                is DataState.Data -> DataState.Data(
                    currentState.data.map { playerData ->
                        playerData.queueItems?.let { items ->
                            val updatedItems = items.map { queueTrack ->
                                if ((queueTrack.track as? AppMediaItem)?.hasAnyMappingFrom(newTrack) == true) {
                                    queueTrack.copy(
                                        track = newTrack,
                                    )
                                } else {
                                    queueTrack
                                }
                            }
                            playerData.copy(
                                queue = (playerData.queue as? DataState.Data)?.let { queueData ->
                                    DataState.Data(
                                        queueData.data.copy(
                                            info = if ((queueData.data.info.currentItem?.track as? AppMediaItem)
                                                    ?.hasAnyMappingFrom(newTrack) == true
                                            ) {
                                                queueData.data.info.copy(
                                                    currentItem = queueData.data.info.currentItem.copy(
                                                        track = newTrack
                                                            .takeIf {
                                                                it.hasAnyMappingFrom(
                                                                    queueData.data.info.currentItem.track as AppMediaItem,
                                                                )
                                                            }
                                                            ?: queueData.data.info.currentItem.track,
                                                    ),
                                                )
                                            } else {
                                                queueData.data.info
                                            },
                                            items = DataState.Data(updatedItems),
                                        ),
                                    )
                                } ?: playerData.queue,
                            )
                        } ?: playerData
                    },
                )
            }
        }
    }

    private fun updatePlayersAndQueues() {
        log.i { "Updating players and queues" }
        launch {
            apiClient.sendRequest(Request.Player.all())
                .resultAs<List<ServerPlayer>>()?.let { playerFactory.createList(it) }
                ?.let { list ->
                    val visiblePlayers = list.filter { it.shouldBeShown }
                    _serverPlayers.update {
                        DataState.Data(visiblePlayers)
                    }
                    visiblePlayers.forEach(::anchorExternalPosition)
                    // Forward to the controller: real player if found, synthetic if not
                    val localPlayerId = settings.sendspinEffectivePlayerId.value
                    val localServerPlayer = visiblePlayers.find { it.id == localPlayerId }
                    localPlayerController.onInitialPlayersReceived(
                        hasLocalPlayer = localServerPlayer != null,
                    )
                    localServerPlayer?.let {
                        localPlayerController.onServerPlayerUpdate(it)
                    }
                }
        }
        launch {
            apiClient.sendRequest(Request.Queue.all())
                .resultAs<List<ServerQueue>>()?.let { queueFactory.createList(it) }?.let { list ->
                    var mergedSnapshot = list
                    _queueInfos.update { retained ->
                        mergeFullQueueSnapshot(retained, list).also { mergedSnapshot = it }
                    }
                    mergedSnapshot.forEach { queueInfo ->
                        anchorQueuePosition(queueInfo)
                    }

                    // Forward the local player's queue to the controller
                    val localPlayerId = settings.sendspinEffectivePlayerId.value
                    val localQueueId = (_serverPlayers.value as? DataState.Data)?.data
                        ?.find { it.id == localPlayerId }?.queueId
                    mergedSnapshot.find { it.id == localPlayerId || it.id == localQueueId }
                        ?.let { localPlayerController.onServerQueueUpdate(it) }
                }
        }
        launch {
            // Gate on queueInfo being merged into _playersData, not just on Data:
            // the _queueInfos→_playersData combine is conflated, so a players-only
            // emission (null queueInfo for all) can land first and make
            // refreshAllPlayersQueueItems skip everyone.
            _playersData.first { state ->
                state is DataState.Data && state.data.any { it.queueInfo != null }
            }
            refreshAllPlayersQueueItems()
        }
    }

    /**
     * Fan out item fetches across every player whose queue metadata is loaded.
     * Without this, items only get fetched for the currently selected player
     * (via the [selectedPlayerIndex] collector), so notifications and pager
     * neighbours show "not loaded" until visited.
     */
    private fun refreshAllPlayersQueueItems() {
        val players = when (val pd = _playersData.value) {
            is DataState.Data -> pd.data
            is DataState.Stale -> pd.data
            else -> return
        }
        players.forEach { pd ->
            if (pd.queueInfo != null) {
                refreshPlayerQueueItems(pd, trigger = QueueItemsTrigger.ALL_PLAYERS)
            }
        }
    }

    /**
     * Refresh one player's queue items, coalescing concurrent requests for the same queue.
     *
     * Two independent triggers converge on every play: the `(playersData, selectedPlayerId)`
     * collector re-fires when `queueInfo` arrives, and the queue-updated event handler refreshes
     * the affected queue. Both are deliberate — each has a bug behind it — so neither is going
     * away, but starting playback tripped both and sent `player_queues/items` twice, about 60ms
     * apart, for the same state.
     *
     * Simply dropping the second would be wrong: a queue that genuinely changes while a fetch is
     * in flight would leave the stale result on screen. So a request arriving during a fetch is
     * remembered instead, and the runner goes round once more when it finishes. The last request
     * always gets a fetch that began after it, and a burst of events costs two round trips rather
     * than one per event.
     */
    private fun refreshPlayerQueueItems(
        fullData: PlayerData,
        forcedQueueData: QueueInfo? = null,
        trigger: QueueItemsTrigger,
    ) {
        launch {
            val queueInfo = forcedQueueData ?: fullData.queueInfo ?: return@launch
            // Answered the question it was added for — two fetches per play are two distinct
            // `QueueItemsUpdated` events from the server, not one of ours firing twice — so it is
            // demoted rather than deleted: release builds drop Debug, and the next time a fetch
            // count looks wrong this is the line that settles it in seconds.
            log.d { "queueItems[${queueInfo.id}] requested by ${trigger.label}" }
            if (!claimQueueItemFetch(queueInfo.id)) {
                log.d { "queueItems[${queueInfo.id}] ${trigger.label} folded into the fetch in flight" }
                return@launch
            }
            try {
                var runAgain: Boolean
                do {
                    fetchQueueItemsInto(fullData, queueInfo)
                    runAgain = consumeOrReleaseQueueItemFetch(queueInfo.id)
                    if (runAgain) {
                        log.d { "queueItems[${queueInfo.id}] re-running for a request that landed mid-fetch" }
                    }
                } while (runAgain)
            } catch (e: CancellationException) {
                releaseQueueItemFetch(queueInfo.id)
                throw e
            }
        }
    }

    /**
     * Which path asked for a queue-items refresh. Exists for the log line above: several call
     * sites converge on one function, and "two requests went out" says nothing about which two.
     *
     * It has already earned its keep once. Starting a podcast issues two `player_queues/items`,
     * and the plausible explanations — coincident triggers, then a self-trigger via the `info`
     * write — were both wrong. The log named `queueEvent` twice: the server emits two
     * `QueueItemsUpdated` events, and this client refetches once per event, on the correct event
     * type. Nothing to fix, which is not a conclusion guesswork was going to reach.
     */
    private enum class QueueItemsTrigger(val label: String) {
        /** The `(playersData, selectedPlayerId)` collector, once `queueInfo` is non-null. */
        QUEUE_INFO_ARRIVED("queueInfoArrived"),

        /** A server queue update, carrying its own fresh `QueueInfo`. */
        QUEUE_EVENT("queueEvent"),

        /**
         * Fan-out across every player with queue metadata, so pager neighbours are not empty.
         * Also the post-reconnect catch-up, via [updatePlayersAndQueues].
         */
        ALL_PLAYERS("allPlayers"),
    }

    /** Queue id -> "another refresh was asked for while this one was running". */
    private val queueItemFetches = mutableMapOf<String, Boolean>()
    private val queueItemFetchLock = Mutex()

    /** True if the caller now owns fetching for [queueId]; false if someone else already does. */
    private suspend fun claimQueueItemFetch(queueId: String): Boolean =
        queueItemFetchLock.withLock {
            if (queueId in queueItemFetches) {
                queueItemFetches[queueId] = true
                false
            } else {
                queueItemFetches[queueId] = false
                true
            }
        }

    /**
     * Whether to fetch again, releasing the claim when not.
     *
     * Both halves happen under one lock deliberately. Checking and releasing separately leaves a
     * gap in which a request can arrive, see the claim still held, decline to start, and then
     * have its flag dropped by the release — that refresh would simply never happen.
     */
    private suspend fun consumeOrReleaseQueueItemFetch(queueId: String): Boolean =
        queueItemFetchLock.withLock {
            if (queueItemFetches[queueId] == true) {
                queueItemFetches[queueId] = false
                true
            } else {
                queueItemFetches.remove(queueId)
                false
            }
        }

    /**
     * Drops the claim after a cancellation. Not done in a `finally`: on the normal path
     * [consumeOrReleaseQueueItemFetch] has already released, and another coroutine may have
     * claimed the queue since — a blanket release would take theirs.
     */
    private suspend fun releaseQueueItemFetch(queueId: String) {
        queueItemFetchLock.withLock { queueItemFetches.remove(queueId) }
    }

    private suspend fun fetchQueueItemsInto(fullData: PlayerData, queueInfo: QueueInfo) {
        val queueTracks = apiClient.sendRequest(Request.Queue.items(queueInfo.id))
            .resultAs<List<ServerQueueItem>>()?.let { queueFactory.createTrackList(it) }

        // Forward to the local player controller so its own PlayerData carries the items.
        if (fullData.isLocal && queueTracks != null) {
            localPlayerController.onQueueItemsLoaded(queueInfo, queueTracks)
        }

        _playersData.update { currentState ->
            when (currentState) {
                is DataState.Error,
                is DataState.Loading,
                is DataState.NoData,
                is DataState.Stale,
                    -> currentState

                is DataState.Data -> DataState.Data(
                    currentState.data.map { playerData ->
                        if (playerData.player.id == fullData.player.id) {
                            // `info` is owned by the combine() over
                            // `_queueInfos`/`localData`; only swap in the
                            // freshly loaded items here. Writing `info`
                            // from this async snapshot would race the
                            // combine and revert optimistic state (e.g.
                            // the shuffle toggle). Fall back to the loaded
                            // `queueInfo` only when no info exists yet.
                            playerData.copy(
                                queue = DataState.Data(
                                    Queue(
                                        info = playerData.queueInfo ?: queueInfo,
                                        items = queueTracks?.let { list ->
                                            DataState.Data(
                                                list,
                                            )
                                        }
                                            ?: DataState.Error(),
                                    ),
                                ),
                            )
                        } else {
                            playerData
                        }
                    },
                )
            }
        }
    }

    fun close() {
        supervisorJob.cancel()
    }

    internal companion object {
        /**
         * How long to wait for a seek to show up in the queue's own elapsed time before pausing
         * regardless. Generous: the server flushes and restarts the stream to seek, and a player
         * that was paused must not be left playing just because that took a while.
         */
        private const val SEEK_SETTLE_TIMEOUT_MS = 5_000L

        /** The queue reports elapsed time in whole-ish seconds; this is "close enough to be it". */
        private const val SEEK_SETTLE_TOLERANCE_SECONDS = 2.0

        /**
         * How long an optimistic play-state override survives without a confirming
         * [PlayerUpdatedEvent] before reverting to server truth. Generous on purpose: slow
         * players (Cast, AirPlay) can take a couple of seconds to actually change state.
         */
        private const val PLAYBACK_OVERRIDE_TIMEOUT_MS = 5_000L

        /**
         * Resolves the effective selected player from the current state.
         * Pure function; re-evaluates on every input change.
         *
         * Invariant: the result is always either `null` or a member of
         * [visiblePlayerIds]. Returning a value not in the list would let a
         * downstream consumer attempt to act on an unreachable player; the
         * persisted choice is held in `SettingsRepository.lastSelectedPlayerId`
         * across loading gaps, not here.
         *
         * Resolution order:
         *  1. [userChoice] if it appears in [visiblePlayerIds] — persisted
         *     explicit pick.
         *  2. First visible player — fallback when no user choice or when
         *     the user's choice is offline.
         *  3. `null` when [visiblePlayerIds] is empty.
         */
        internal fun resolveSelectedPlayerId(
            visiblePlayerIds: List<String>,
            userChoice: String?,
        ): String? {
            if (userChoice != null && userChoice in visiblePlayerIds) return userChoice
            return visiblePlayerIds.firstOrNull()
        }

        /**
         * What to show while a newly-authenticated connection re-fetches everything.
         * Pure function; the fetch itself is unconditional (see the call site).
         *
         * Any players we already hold — fresh or [DataState.Stale] from a disconnection of
         * either flavour — stay on screen and are simply promoted back to [DataState.Data].
         * The re-fetch overwrites them in place a moment later, so the only thing this
         * decides is whether the user watches a populated list refresh itself or watches it
         * disappear and come back. Only when there is genuinely nothing to show — a cold
         * start, or data cleared by a logout — does [DataState.Loading] apply.
         *
         * [DataState.Data] is returned as-is rather than rebuilt, so an already-fresh state
         * doesn't emit an equal-but-new value to every downstream collector.
         */
        internal fun preserveThroughResync(
            current: DataState<List<Player>>,
        ): DataState<List<Player>> = when (current) {
            is DataState.Data -> current
            is DataState.Stale -> DataState.Data(current.data)
            is DataState.Loading,
            is DataState.NoData,
            is DataState.Error,
                -> DataState.Loading()
        }
    }
}
