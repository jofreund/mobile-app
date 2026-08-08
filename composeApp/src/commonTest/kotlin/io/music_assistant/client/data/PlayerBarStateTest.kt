package io.music_assistant.client.data

import io.music_assistant.client.data.model.client.PlayerData
import io.music_assistant.client.data.model.client.PlayerDataFixtures
import io.music_assistant.client.data.model.client.PlayerType
import io.music_assistant.client.ui.compose.common.DataState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
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
}
