package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.MediaType
import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.PlayerDataFixtures
import io.music_assistant.client.data.model.client.PlayerMedia
import io.music_assistant.client.data.model.client.PlayerType
import io.music_assistant.client.data.model.client.Queue
import io.music_assistant.client.data.model.client.QueueTrack
import io.music_assistant.client.data.model.client.items.PlayableItem
import io.music_assistant.client.data.model.client.testAudiobook
import io.music_assistant.client.data.model.client.testPodcastEpisode
import io.music_assistant.client.data.model.client.testTrack
import io.music_assistant.client.ui.compose.common.DataState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Unit tests for [buildPlayerBarState], the projection the whole native player reads —
 * mini player, expanded player, queue list and group settings sheet all render from it.
 *
 * It's a pure function over (players, selection), but it's also where several rules that
 * only exist in the Swift UI's head get encoded: which volume a grouped player reports,
 * when the volume slider is suppressed entirely, and the bound-first member ordering the
 * group sheet renders without re-sorting. Those are the ones pinned down here.
 */
class PlayerBarStateTest {
    private fun stateOf(vararg players: PlayerData, selectedIndex: Int? = 0) =
        buildPlayerBarState(DataState.Data(players.toList()), selectedIndex) as PlayerBarState.Data

    @Test
    fun `non-data player state collapses to loading`() {
        assertTrue(buildPlayerBarState(DataState.Loading(), 0) is PlayerBarState.Loading)
        assertTrue(buildPlayerBarState(DataState.NoData(), 0) is PlayerBarState.Loading)
    }

    @Test
    fun `empty player list is empty rather than loading`() {
        assertTrue(buildPlayerBarState(DataState.Data(emptyList()), 0) is PlayerBarState.Empty)
    }

    @Test
    fun `selection out of range falls back to the first player`() {
        // Nothing downstream range-checks this, and Swift indexes straight into the array.
        assertEquals(0, stateOf(PlayerDataFixtures.playerData(), selectedIndex = 7).selectedIndex)
        assertEquals(0, stateOf(PlayerDataFixtures.playerData(), selectedIndex = null).selectedIndex)
        assertEquals(0, stateOf(PlayerDataFixtures.playerData(), selectedIndex = -1).selectedIndex)
    }

    @Test
    fun `a player fed by another source reports its own position when it has no queue`() {
        // A HomePod on Apple Music: MA knows the media but its queue is idle, so the snapshot
        // is the player's reported position projected to now.
        val external = externalPlayer(elapsedTime = 60.0, lastUpdated = 1_000.0)
        val state = buildPlayerBarState(DataState.Data(listOf(external)), 0, nowEpochSec = 1_010.0)
        val item = (state as PlayerBarState.Data).players.single()
        assertEquals(70.0, item.elapsedTime)
        assertEquals(201.0, item.duration)
    }

    @Test
    fun `a player fed by another source scrubs only when it seeks on its own`() {
        // The server hands such a seek to the player and refuses it without the feature.
        val cannot = externalPlayer(elapsedTime = 60.0, lastUpdated = 1_000.0)
        assertFalse(stateOf(cannot).players.single().canSeek)
        val can = cannot.copy(player = cannot.player.copy(supportsSeek = true))
        assertTrue(stateOf(can).players.single().canSeek)
    }

    @Test
    fun `a player on a queue scrubs whatever it can do on its own`() {
        // The queue takes the seek; the player's own feature list is not consulted.
        assertTrue(stateOf(PlayerDataFixtures.playerData()).players.single().canSeek)
    }

    @Test
    fun `a queue-less player with no reported position has no elapsed time`() {
        val external = externalPlayer(elapsedTime = null, lastUpdated = null)
        assertNull(stateOf(external).players.single().elapsedTime)
    }

    private fun externalPlayer(elapsedTime: Double?, lastUpdated: Double?): PlayerData {
        val media = PlayerMedia(
            title = "The Sum",
            artist = "Lambert & Dekker",
            album = null,
            imageUrl = null,
            duration = 201.0,
            queueId = null,
            queueItemId = null,
            mediaType = MediaType.TRACK,
            uri = null,
        )
        return PlayerData(
            player = PlayerDataFixtures.player(queueId = "External", currentMedia = media).copy(
                elapsedTime = elapsedTime,
                elapsedTimeLastUpdated = lastUpdated,
            ),
            queue = DataState.NoData(),
            parentBind = null,
            childrenBinds = emptyList(),
        )
    }

    @Test
    fun `crossfade support is projected apart from the crossfade value`() {
        // A server that never reports crossfade and one that reports it off both leave
        // crossfadeEnabled false; only crossfadeSupported separates "no row" from "row, off",
        // which is the whole reason the nullable is split in two across the bridge.
        val unsupported = queueSettingsPlayer(crossfadeEnabled = null)
        assertEquals(false, stateOf(unsupported).players.single().crossfadeSupported)
        assertEquals(false, stateOf(unsupported).players.single().crossfadeEnabled)

        val off = queueSettingsPlayer(crossfadeEnabled = false)
        assertEquals(true, stateOf(off).players.single().crossfadeSupported)
        assertEquals(false, stateOf(off).players.single().crossfadeEnabled)

        val on = queueSettingsPlayer(crossfadeEnabled = true)
        assertEquals(true, stateOf(on).players.single().crossfadeSupported)
        assertEquals(true, stateOf(on).players.single().crossfadeEnabled)
    }

    @Test
    fun `autoplay projects as a definite boolean even when the queue never reported it`() {
        assertEquals(true, stateOf(queueSettingsPlayer(autoPlayEnabled = true)).players.single().autoplayEnabled)
        assertEquals(false, stateOf(queueSettingsPlayer(autoPlayEnabled = null)).players.single().autoplayEnabled)
    }

    @Test
    fun `playback speed is passed through and null stands for a server without it`() {
        // Unlike crossfade there is no separate "supported" flag: the value itself is the gate,
        // and Swift draws the row only when it is present (and the item is spoken word).
        assertNull(stateOf(queueSettingsPlayer(playbackSpeed = null)).players.single().playbackSpeed)
        assertEquals(1.5, stateOf(queueSettingsPlayer(playbackSpeed = 1.5)).players.single().playbackSpeed)
    }

    /** A player whose queue carries the overflow-menu settings at the given values. */
    private fun queueSettingsPlayer(
        autoPlayEnabled: Boolean? = false,
        crossfadeEnabled: Boolean? = null,
        playbackSpeed: Double? = null,
    ): PlayerData {
        val base = PlayerDataFixtures.playerData()
        val info = base.queueInfo ?: error("fixture has no queue")
        return base.copy(
            queue = DataState.Data(
                Queue(
                    info = info.copy(
                        autoPlayEnabled = autoPlayEnabled,
                        crossfadeEnabled = crossfadeEnabled,
                        playbackSpeed = playbackSpeed,
                    ),
                    items = DataState.NoData(),
                ),
            ),
        )
    }

    @Test
    fun `a grouped player reports group volume but keeps its own as ownVolume`() {
        // The expanded player's inline slider drives the group as a whole, while the group
        // settings sheet's pivot row edits this speaker alone — so both have to survive the
        // projection separately.
        val base = PlayerDataFixtures.playerData()
        val grouped = base.copy(
            player = base.player.copy(
                groupMembers = setOf("child"),
                groupVolume = 30f,
                volumeLevel = 50f,
            ),
        )

        val item = stateOf(grouped).players.single()

        assertEquals(30f, item.volumeLevel)
        assertEquals(50f, item.ownVolume)
        assertTrue(item.isGrouped)
        assertFalse(item.isGroup)
    }

    @Test
    fun `volume is null when the slider is not accessible`() {
        // Swift keys "is there a volume control at all" off this being null, so a player that
        // can't set volume must not report a level it would then render as an active slider.
        val base = PlayerDataFixtures.playerData()
        val noVolume = base.copy(player = base.player.copy(canSetVolume = false))

        assertNull(stateOf(noVolume).players.single().volumeLevel)
    }

    @Test
    fun `a group-type player is flagged as group but not grouped`() {
        val group = PlayerDataFixtures.playerData(playerType = PlayerType.GROUP)
        val item = stateOf(group).players.single()

        assertTrue(item.isGroup)
        // isGrouped means "a normal player currently following a group", which a GROUP is not.
        assertFalse(item.isGrouped)
    }

    @Test
    fun `group members are ordered bound first`() {
        // The group sheet renders this order as-is; joined speakers belong above candidates.
        val base = PlayerDataFixtures.playerData()
        val withMembers = base.copy(
            childrenBinds = listOf(
                PlayerDataFixtures.bind().copy(id = "unbound-a", isBound = false),
                PlayerDataFixtures.bind().copy(id = "bound", isBound = true),
                PlayerDataFixtures.bind().copy(id = "unbound-b", isBound = false),
            ),
        )

        val ids = stateOf(withMembers).players.single().groupMembers.map { it.id }

        assertEquals("bound", ids.first())
        // Relative order within each group is preserved (the sort is stable).
        assertEquals(listOf("bound", "unbound-a", "unbound-b"), ids)
    }

    @Test
    fun `a member with no mute control reports canMute false rather than a bogus mute state`() {
        // ChildBind carries a nullable isMuted; the bridge flattens it because Swift can't
        // read a boxed KotlinBoolean? cleanly. The null must not collapse into "unmuted".
        val base = PlayerDataFixtures.playerData()
        val withMembers = base.copy(
            childrenBinds = listOf(
                PlayerDataFixtures.bind().copy(id = "no-mute", isMuted = null, isBound = true),
                PlayerDataFixtures.bind().copy(id = "muted", isMuted = true, isBound = true),
            ),
        )

        val members = stateOf(withMembers).players.single().groupMembers.associateBy { it.id }

        assertFalse(members.getValue("no-mute").canMute)
        assertFalse(members.getValue("no-mute").isMuted)
        assertTrue(members.getValue("muted").canMute)
        assertTrue(members.getValue("muted").isMuted)
    }

    @Test
    fun `players with no queue still project with the player id as queue id`() {
        // Queue actions key on this id; falling back to the player id is what lets a player
        // that has never played anything still accept "play this item".
        val data = PlayerDataFixtures.playerData()
        val item = stateOf(data).players.single()

        assertTrue(item.queueItems.isEmpty())
        assertNull(item.currentQueueItemId)
        assertTrue(item.currentItemChapters.isEmpty())
        assertEquals(data.queueOrPlayerId, item.queueId)
    }

    /** [PlayerDataFixtures.playerData] with [item] installed as the current queue item. */
    private fun playerDataPlaying(item: PlayableItem): PlayerData {
        val base = PlayerDataFixtures.playerData()
        val info = (base.queue as DataState.Data<Queue>).data.info
        return base.copy(
            queue = DataState.Data(
                Queue(
                    info = info.copy(
                        currentIndex = 0,
                        currentItem = QueueTrack(
                            id = "queue-item-1",
                            track = item,
                            isPlayable = true,
                            format = null,
                            dsp = null,
                            provider = "test",
                        ),
                    ),
                    items = DataState.NoData(),
                ),
            ),
        )
    }

    @Test
    fun `spoken word covers audiobooks and podcast episodes but not music`() {
        // Swift swaps the expanded player's shuffle/repeat buttons for skip back/forward on
        // this flag alone, so a music track wrongly flagged loses two controls outright.
        assertTrue(stateOf(playerDataPlaying(testAudiobook())).players.single().isSpokenWord)
        assertTrue(stateOf(playerDataPlaying(testPodcastEpisode())).players.single().isSpokenWord)
        assertFalse(stateOf(playerDataPlaying(testTrack())).players.single().isSpokenWord)
    }

    @Test
    fun `a player with nothing playing is not spoken word`() {
        // Null track, not "unknown": a player between items keeps the music transport rather
        // than flipping its outer two buttons on every queue boundary.
        assertFalse(stateOf(PlayerDataFixtures.playerData()).players.single().isSpokenWord)
    }

    // The `distinctUntilChanged` predicate behind `MainDataSource.playerBarState`. Most of these
    // assert states are *not* equivalent, because over-suppression is the dangerous direction:
    // a dropped emission is a UI that silently stops updating, which is far harder to notice
    // than an extra one.

    private fun projected() = stateOf(PlayerDataFixtures.playerData())

    private fun PlayerBarState.Data.mutatingFirst(
        transform: (PlayerBarItem) -> PlayerBarItem,
    ) = copy(players = players.mapIndexed { index, item -> if (index == 0) transform(item) else item })

    @Test
    fun `a queue time tick alone is suppressed`() {
        val base = projected()
        val ticked = base.mutatingFirst { it.copy(elapsedTime = (it.elapsedTime ?: 0.0) + 1.0) }
        assertTrue(playerBarStatesEquivalentIgnoringElapsed(base, ticked))
    }

    @Test
    fun `an unchanged projection is suppressed`() {
        val base = projected()
        assertTrue(playerBarStatesEquivalentIgnoringElapsed(base, base))
    }

    @Test
    fun `a track change is not suppressed even though elapsed resets with it`() {
        // The case most at risk: advancing a track resets elapsedTime *and* changes the item.
        // Keying only on elapsedTime would hide the part that matters.
        val base = projected()
        val advanced = base.mutatingFirst {
            it.copy(currentQueueItemId = "next-item", title = "Next Track", elapsedTime = 0.0)
        }
        assertFalse(playerBarStatesEquivalentIgnoringElapsed(base, advanced))
    }

    @Test
    fun `play pause is not suppressed`() {
        val base = projected()
        assertFalse(
            playerBarStatesEquivalentIgnoringElapsed(base, base.mutatingFirst { it.copy(isPlaying = !it.isPlaying) }),
        )
    }

    @Test
    fun `volume and mute changes are not suppressed`() {
        val base = projected()
        assertFalse(
            playerBarStatesEquivalentIgnoringElapsed(base, base.mutatingFirst { it.copy(volumeLevel = 0.42f) }),
        )
        assertFalse(
            playerBarStatesEquivalentIgnoringElapsed(base, base.mutatingFirst { it.copy(isMuted = !it.isMuted) }),
        )
    }

    @Test
    fun `sleep timer expiry reaches the projected item`() {
        val base = PlayerDataFixtures.playerData()
        val withTimer = base.copy(player = base.player.copy(sleepTimerExpiresAt = 1782000000.5))

        assertEquals(1782000000.5, stateOf(withTimer).players.single().sleepTimerExpiresAt)
        assertNull(stateOf(base).players.single().sleepTimerExpiresAt)
    }

    @Test
    fun `sleep timer change is not suppressed`() {
        // The expiry is a static timestamp (set/clear only, never ticking), so letting the
        // plain data-class comparison see it costs one extra emission per timer change.
        val base = projected()
        assertFalse(
            playerBarStatesEquivalentIgnoringElapsed(
                base,
                base.mutatingFirst { it.copy(sleepTimerExpiresAt = 123.0) },
            ),
        )
    }

    @Test
    fun `queue contents changing is not suppressed`() {
        // Reordering and removal both have to get through, or the queue list freezes after a
        // drag — the exact class of bug this projection has already produced twice.
        val base = projected()
        val withItems = base.mutatingFirst {
            it.copy(
                queueItems = listOf(
                    QueueBarItem("a", "A", null, null, isPlayable = true, trackItem = null),
                    QueueBarItem("b", "B", null, null, isPlayable = true, trackItem = null),
                ),
            )
        }
        val reordered = withItems.mutatingFirst { it.copy(queueItems = it.queueItems.reversed()) }
        val removed = withItems.mutatingFirst { it.copy(queueItems = it.queueItems.drop(1)) }

        assertFalse(playerBarStatesEquivalentIgnoringElapsed(base, withItems))
        assertFalse(playerBarStatesEquivalentIgnoringElapsed(withItems, reordered))
        assertFalse(playerBarStatesEquivalentIgnoringElapsed(withItems, removed))
    }

    @Test
    fun `group membership changes are not suppressed`() {
        val base = projected()
        assertFalse(
            playerBarStatesEquivalentIgnoringElapsed(base, base.mutatingFirst { it.copy(isGrouped = !it.isGrouped) }),
        )
    }

    @Test
    fun `selection and player list changes are not suppressed`() {
        val two = stateOf(PlayerDataFixtures.playerData(), PlayerDataFixtures.playerData())
        assertFalse(playerBarStatesEquivalentIgnoringElapsed(two, two.copy(selectedIndex = 1)))
        assertFalse(playerBarStatesEquivalentIgnoringElapsed(two, two.copy(players = two.players.drop(1))))
    }

    @Test
    fun `transitions in and out of loading are not suppressed`() {
        val base = projected()
        assertFalse(playerBarStatesEquivalentIgnoringElapsed(PlayerBarState.Loading, base))
        assertFalse(playerBarStatesEquivalentIgnoringElapsed(base, PlayerBarState.Empty))
        // Repeats of the same non-Data state still collapse, so a stuck connection doesn't
        // re-notify Swift on every rebuild.
        assertTrue(playerBarStatesEquivalentIgnoringElapsed(PlayerBarState.Loading, PlayerBarState.Loading))
    }

    // QueueProjectionCache. The failure that matters is a *stale hit* — returning last tick's
    // items after the queue changed — so most of this checks the cache lets real changes through.

    private fun queueTracks(vararg ids: String) = with(PlayerDataFixtures) {
        ids.map { testTrack().toQueueTrack(id = it) }
    }

    /** [PlayerDataFixtures.playerData] with a loaded queue, reusing whatever info it built. */
    private fun playerDataWithQueue(tracks: List<QueueTrack>): PlayerData {
        val base = PlayerDataFixtures.playerData()
        val queue = (base.queue as DataState.Data).data
        return base.copy(queue = DataState.Data(queue.copy(items = DataState.Data(tracks))))
    }

    @Test
    fun `an unchanged queue is projected once and reused by identity`() {
        // The point of the cache: same source object, same result object. Reusing the instance
        // also lets the distinctUntilChanged comparison short-circuit instead of walking items.
        val cache = QueueProjectionCache()
        val source = queueTracks("a", "b")

        val first = cache.project("player-1", source)
        val second = cache.project("player-1", source)

        assertSame(first, second)
    }

    @Test
    fun `a changed queue is re-projected`() {
        val cache = QueueProjectionCache()
        cache.project("player-1", queueTracks("a", "b"))

        val afterChange = cache.project("player-1", queueTracks("a", "b", "c"))

        assertEquals(listOf("a", "b", "c"), afterChange.map { it.id })
    }

    @Test
    fun `a reordered queue of the same tracks is re-projected`() {
        // Same size, same contents, different order — the case a sloppy size-only guard misses.
        val cache = QueueProjectionCache()
        cache.project("player-1", queueTracks("a", "b"))

        val reordered = cache.project("player-1", queueTracks("b", "a"))

        assertEquals(listOf("b", "a"), reordered.map { it.id })
    }

    @Test
    fun `an equal but distinct source re-projects rather than reusing`() {
        // Documents the identity-not-equality choice: a miss costs a re-map, never correctness.
        // Comparing by equality here would cost exactly the walk the cache exists to avoid.
        val cache = QueueProjectionCache()
        val first = cache.project("player-1", queueTracks("a"))
        val second = cache.project("player-1", queueTracks("a"))

        assertNotSame(first, second)
        assertEquals(first, second)
    }

    @Test
    fun `players do not share cache entries`() {
        val cache = QueueProjectionCache()
        val oneSource = queueTracks("a")
        val twoSource = queueTracks("b")

        val one = cache.project("player-1", oneSource)
        val two = cache.project("player-2", twoSource)

        assertEquals(listOf("a"), one.map { it.id })
        assertEquals(listOf("b"), two.map { it.id })
        // And each still hits its own entry afterwards.
        assertSame(one, cache.project("player-1", oneSource))
        assertSame(two, cache.project("player-2", twoSource))
    }

    @Test
    fun `an emptied queue drops its entry and projects empty`() {
        val cache = QueueProjectionCache()
        cache.project("player-1", queueTracks("a"))

        assertTrue(cache.project("player-1", emptyList()).isEmpty())
        assertTrue(cache.project("player-1", null).isEmpty())
    }

    @Test
    fun `retainOnly evicts players that are gone`() {
        val cache = QueueProjectionCache()
        val source = queueTracks("a")
        val before = cache.project("player-1", source)

        cache.retainOnly(setOf("player-2"))

        // Same source object, but the entry was evicted — so this re-projects rather than
        // resurrecting a queue belonging to a player that no longer exists.
        assertNotSame(before, cache.project("player-1", source))
    }

    @Test
    fun `repeated projection through buildPlayerBarState reuses the queue items`() {
        // End-to-end: what MainDataSource actually does on a queue-time tick.
        val cache = QueueProjectionCache()
        val state = DataState.Data(listOf(playerDataWithQueue(queueTracks("a", "b"))))

        val first = buildPlayerBarState(state, 0, cache) as PlayerBarState.Data
        val second = buildPlayerBarState(state, 0, cache) as PlayerBarState.Data

        assertSame(first.players.single().queueItems, second.players.single().queueItems)
    }

    // Only the selected player's queue is projected. The expanded player is the one place a queue
    // is drawn and it shows the selected player alone, so every other player's items crossed the
    // bridge for nobody — and Swift walked each of them on every real change to prove it.

    @Test
    fun `only the selected player carries queue items`() {
        val first = playerDataWithQueue(queueTracks("a", "b"))
        val second = playerDataWithQueue(queueTracks("c", "d", "e"))

        val data = stateOf(first, second, selectedIndex = 1)

        assertTrue(data.players[0].queueItems.isEmpty())
        assertEquals(listOf("c", "d", "e"), data.players[1].queueItems.map { it.id })
        // Queue *actions* still need every player's id — only the item list is withheld.
        assertEquals(first.queueOrPlayerId, data.players[0].queueId)
    }

    @Test
    fun `moving the selection carries the queue with it`() {
        // Selection is an input to the projection, so the emission that moves it is the one
        // that carries the newly selected player's queue — there is no gap for Swift to bridge.
        val cache = QueueProjectionCache()
        val state = DataState.Data(
            listOf(playerDataWithQueue(queueTracks("a")), playerDataWithQueue(queueTracks("b"))),
        )

        val onFirst = buildPlayerBarState(state, 0, cache) as PlayerBarState.Data
        assertEquals(listOf("a"), onFirst.players[0].queueItems.map { it.id })
        assertTrue(onFirst.players[1].queueItems.isEmpty())

        val onSecond = buildPlayerBarState(state, 1, cache) as PlayerBarState.Data
        assertTrue(onSecond.players[0].queueItems.isEmpty())
        assertEquals(listOf("b"), onSecond.players[1].queueItems.map { it.id })
    }

    @Test
    fun `an out of range selection projects the first player's queue`() {
        // The fallback the selectedIndex already had, applied to the queue too, so the two can't
        // disagree about which player is selected.
        val data = stateOf(
            playerDataWithQueue(queueTracks("a")),
            playerDataWithQueue(queueTracks("b")),
            selectedIndex = 7,
        )
        assertEquals(0, data.selectedIndex)
        assertEquals(listOf("a"), data.players[0].queueItems.map { it.id })
        assertTrue(data.players[1].queueItems.isEmpty())
    }

    // LiveActivitySnapshot: what the lock screen card reads, and nothing else — so that the
    // distinctUntilChanged in front of it drops everything the card does not show.

    // The fixture player is playing by default; both states have to be explicit here.
    private fun playing(data: PlayerData, isPlaying: Boolean) =
        data.copy(player = data.player.copy(isPlaying = isPlaying))

    @Test
    fun `snapshot is null while loading or empty`() {
        assertNull(liveActivitySnapshot(PlayerBarState.Loading))
        assertNull(liveActivitySnapshot(PlayerBarState.Empty))
    }

    @Test
    fun `snapshot mirrors the selected player`() {
        val first = PlayerDataFixtures.playerData(name = "Kitchen")
        val second = PlayerDataFixtures.playerData(name = "Study")
        val data = stateOf(first, second, selectedIndex = 1)

        val snapshot = liveActivitySnapshot(data)!!

        assertEquals(second.playerId, snapshot.playerId)
        assertEquals(data.players[1].name, snapshot.playerName)
        assertEquals(data.players[1].title, snapshot.title)
        assertEquals(data.players[1].artworkUrl, snapshot.artworkUrl)
        assertEquals(data.players[1].isPlaying, snapshot.isPlaying)
    }

    @Test
    fun `anyPlaying looks at every player not just the selected one`() {
        // The "while playing" setting is worded over all players, and the card follows the
        // wording: a paused selected player keeps its card while another player plays.
        val paused = playing(PlayerDataFixtures.playerData(), isPlaying = false)
        val other = playing(PlayerDataFixtures.playerData(), isPlaying = true)
        val alsoPaused = playing(PlayerDataFixtures.playerData(), isPlaying = false)

        val snapshot = liveActivitySnapshot(stateOf(paused, other, selectedIndex = 0))!!

        assertFalse(snapshot.isPlaying)
        assertTrue(snapshot.anyPlaying)
        assertFalse(liveActivitySnapshot(stateOf(paused, alsoPaused))!!.anyPlaying)
    }

    @Test
    fun `changes the card does not show leave the snapshot equal`() {
        // This equality is what lets `distinctUntilChanged` keep ActivityKit out of a volume
        // drag or a queue edit.
        val base = stateOf(playerDataWithQueue(queueTracks("a", "b")), PlayerDataFixtures.playerData())
        val volume = base.mutatingFirst { it.copy(volumeLevel = 0.42f, isMuted = true) }
        val queue = base.mutatingFirst { it.copy(queueItems = it.queueItems.reversed()) }
        val elapsed = base.mutatingFirst { it.copy(elapsedTime = 999.0) }

        assertEquals(liveActivitySnapshot(base), liveActivitySnapshot(volume))
        assertEquals(liveActivitySnapshot(base), liveActivitySnapshot(queue))
        assertEquals(liveActivitySnapshot(base), liveActivitySnapshot(elapsed))
    }

    @Test
    fun `changes the card shows change the snapshot`() {
        val base = stateOf(PlayerDataFixtures.playerData(), PlayerDataFixtures.playerData())
        val play = base.mutatingFirst { it.copy(isPlaying = !it.isPlaying) }
        val title = base.mutatingFirst { it.copy(title = "Something else") }
        val reselect = base.copy(selectedIndex = 1)

        assertFalse(liveActivitySnapshot(base) == liveActivitySnapshot(play))
        assertFalse(liveActivitySnapshot(base) == liveActivitySnapshot(title))
        assertFalse(liveActivitySnapshot(base) == liveActivitySnapshot(reselect))
    }
}
