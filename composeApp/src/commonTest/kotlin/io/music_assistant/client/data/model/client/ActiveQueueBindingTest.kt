package io.music_assistant.client.data.model.client

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Which queue a player is playing from. A speaker that is synced to another, or taken over
 * by a group, plays that one's queue — the server redirects playback commands there and
 * reports the position against it, and its own queue sits idle. Binding it to the idle one
 * is how an audiobook on a grouped speaker read 0:00 no matter how far in it was, and why a
 * chapter picked there appeared to do nothing.
 */
class ActiveQueueBindingTest {
    private fun player(
        id: String,
        queueId: String = id,
        syncedTo: String? = null,
        activeGroup: String? = null,
    ) = PlayerDataFixtures.player(id = id, queueId = queueId)
        .copy(syncedTo = syncedTo, activeGroup = activeGroup)

    @Test
    fun anUngroupedPlayerPlaysItsOwnQueue() {
        val solo = player("office")

        assertEquals("office", solo.activeQueueId(listOf(solo)))
    }

    @Test
    fun aSyncedPlayerPlaysTheSyncLeadersQueue() {
        val leader = player("leader")
        val member = player("noah", syncedTo = "leader")

        assertEquals("leader", member.activeQueueId(listOf(leader, member)))
    }

    @Test
    fun aPlayerTakenOverByAGroupPlaysTheGroupsQueue() {
        val group = player("syncgroup_hckgyfg7")
        val member = player("noah", activeGroup = "syncgroup_hckgyfg7")

        assertEquals("syncgroup_hckgyfg7", member.activeQueueId(listOf(group, member)))
    }

    @Test
    fun aParentTheServerDidNotSendLeavesThePlayerOnItsOwnQueue() {
        val member = player("noah", activeGroup = "syncgroup_gone")

        assertEquals("noah", member.activeQueueId(listOf(member)))
    }

    @Test
    fun aPlayerNamingItselfAsItsParentIsNotFollowed() {
        val self = player("noah", syncedTo = "noah")

        assertEquals("noah", self.activeQueueId(listOf(self)))
    }

    @Test
    fun aCycleInTheReportedParentsTerminates() {
        val a = player("a", syncedTo = "b")
        val b = player("b", syncedTo = "a")

        // Whatever it settles on, it must settle: the rebuild runs on every player update.
        assertEquals("a", a.activeQueueId(listOf(a, b)))
    }

    @Test
    fun aPlayerWithNoQueueAtAllStaysWithout() {
        val solo = PlayerDataFixtures.player(id = "office").copy(queueId = null)

        assertNull(solo.activeQueueId(listOf(solo)))
    }
}
