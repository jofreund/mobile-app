package io.music_assistant.client.settings

import com.russhwolf.settings.MapSettings
import io.music_assistant.sendspin.api.AudioCodec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** The local-player settings carried over from the fork's own Sendspin to `:sendspin-kmp`. */
class SendspinSettingsMigrationTest {
    @Test
    fun eachOldMegabyteTierKeepsItsPlaceAsSeconds() {
        assertEquals(5, SettingsRepository.bufferSecondsForMegabytes(5))
        assertEquals(10, SettingsRepository.bufferSecondsForMegabytes(15))
        assertEquals(20, SettingsRepository.bufferSecondsForMegabytes(30))
        assertEquals(30, SettingsRepository.bufferSecondsForMegabytes(50))
    }

    @Test
    fun aStoredMegabyteSizeIsMovedToSecondsOnce() {
        val store = MapSettings().apply { putInt("sendspin_buffer_capacity_mb", 30) }

        assertEquals(20, SettingsRepository(store).sendspinBufferSeconds.value)
        assertEquals(20, store.getIntOrNull("sendspin_buffer_seconds"))
        assertFalse(store.hasKey("sendspin_buffer_capacity_mb"))
    }

    @Test
    fun aFreshInstallGetsTheDefaults() {
        val repository = SettingsRepository(MapSettings())

        assertEquals(SettingsRepository.BUFFER_SECONDS_DEFAULT, repository.sendspinBufferSeconds.value)
        assertEquals(SettingsRepository.DEFAULT_CODEC, repository.sendspinCodecPreference.value)
    }

    @Test
    fun theStoredCodecNameSurvivesAndAnUnknownOneFallsBack() {
        assertEquals(
            AudioCodec.FLAC,
            SettingsRepository(MapSettings().apply { putString("sendspin_codec_preference", "FLAC") })
                .sendspinCodecPreference.value,
        )
        assertEquals(
            SettingsRepository.DEFAULT_CODEC,
            SettingsRepository(MapSettings().apply { putString("sendspin_codec_preference", "AAC") })
                .sendspinCodecPreference.value,
        )
    }

    @Test
    fun hiResAppliesToLosslessCodecsOnly() {
        assertEquals(24, SettingsRepository.effectiveSendspinBitDepth(AudioCodec.FLAC, storedBitDepth = 24))
        assertEquals(24, SettingsRepository.effectiveSendspinBitDepth(AudioCodec.PCM, storedBitDepth = 24))
        assertEquals(16, SettingsRepository.effectiveSendspinBitDepth(AudioCodec.OPUS, storedBitDepth = 24))
        assertEquals(16, SettingsRepository.effectiveSendspinBitDepth(AudioCodec.FLAC, storedBitDepth = 16))
    }

    @Test
    fun onlySixteenAndTwentyFourAreStored() {
        val repository = SettingsRepository(MapSettings().apply { putInt("sendspin_bit_depth", 32) })
        assertEquals(16, repository.sendspinBitDepth.value)

        repository.setSendspinBitDepth(24)
        assertEquals(24, repository.sendspinBitDepth.value)
        repository.setSendspinBitDepth(20)
        assertEquals(16, repository.sendspinBitDepth.value)
    }

    @Test
    fun bufferSecondsSnapToTheGrid() {
        val repository = SettingsRepository(MapSettings())

        repository.setSendspinBufferSeconds(12)
        assertEquals(10, repository.sendspinBufferSeconds.value)
        repository.setSendspinBufferSeconds(99)
        assertEquals(SettingsRepository.BUFFER_SECONDS_MAX, repository.sendspinBufferSeconds.value)
    }
}
