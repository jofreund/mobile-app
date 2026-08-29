package io.music_assistant.client.settings

import com.russhwolf.settings.MapSettings
import kotlin.test.Test
import kotlin.test.assertEquals

class LiveActivityVisibilityRepoTest {
    @Test
    fun `defaults to always when nothing stored`() {
        val repo = SettingsRepository(MapSettings())
        assertEquals(LiveActivityVisibility.ALWAYS, repo.liveActivityVisibility.value)
    }

    @Test
    fun `set then read back`() {
        val repo = SettingsRepository(MapSettings())
        repo.setLiveActivityVisibility(LiveActivityVisibility.WHILE_PLAYING)
        assertEquals(LiveActivityVisibility.WHILE_PLAYING, repo.liveActivityVisibility.value)
    }

    @Test
    fun `survives a fresh repository over the same storage`() {
        val settings = MapSettings()
        SettingsRepository(settings).setLiveActivityVisibility(LiveActivityVisibility.WHILE_PLAYING)
        assertEquals(
            LiveActivityVisibility.WHILE_PLAYING,
            SettingsRepository(settings).liveActivityVisibility.value,
        )
    }

    @Test
    fun `unrecognized stored value degrades to always`() {
        val settings = MapSettings().apply { putString("live_activity_visibility", "SOMETIMES") }
        assertEquals(LiveActivityVisibility.ALWAYS, SettingsRepository(settings).liveActivityVisibility.value)
    }
}
