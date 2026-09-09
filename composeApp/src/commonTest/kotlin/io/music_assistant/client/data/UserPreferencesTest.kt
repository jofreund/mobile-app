package io.music_assistant.client.data

import io.music_assistant.client.data.model.server.ServerUser
import io.music_assistant.client.data.model.server.ServerUserPreferences
import io.music_assistant.client.utils.myJson
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

/**
 * `auth/me` is where the app learns both who it is signed in as and what that user's
 * preferences are. The id matters because the server keeps per-user records — the playlog,
 * and so an audiobook's resume point — and events about them name their user.
 */
class UserPreferencesTest {
    @Test
    fun decodesTheSignedInUserFromAuthMe() {
        val json = """{
            "user_id": "nHDDVU3KrxQKf",
            "username": "jo",
            "role": "admin",
            "preferences": {"audiobook_chapter_progress": false}
        }"""

        val user = myJson.decodeFromString<ServerUser>(json)
        val preferences = UserPreferences().apply { update(user) }

        assertEquals("nHDDVU3KrxQKf", preferences.signedInUserId)
        assertFalse(preferences.isChapterProgressEnabled)
    }

    @Test
    fun aServerThatNamesNoUserLeavesTheKnownIdAlone() {
        val preferences = UserPreferences().apply {
            update(ServerUser(userId = "user-1"))
            update(ServerUser(preferences = ServerUserPreferences()))
        }

        assertEquals("user-1", preferences.signedInUserId)
    }

    @Test
    fun clearDropsTheUserSoTheNextServerDoesNotInheritIt() {
        val preferences = UserPreferences().apply {
            update(ServerUser(userId = "user-1"))
            clear()
        }

        assertNull(preferences.signedInUserId)
    }
}
