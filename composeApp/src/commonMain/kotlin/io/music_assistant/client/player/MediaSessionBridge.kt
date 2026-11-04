@file:Suppress("EXPECT_ACTUAL_CLASSIFIERS_ARE_IN_BETA_WARNING")

package io.music_assistant.client.player

/**
 * Platform now-playing surface settings that are not the audio sink's business.
 * iOS forwards them to the native player, which owns the remote command center.
 */
expect class MediaSessionBridge() {
    fun setLongFormSeekIntervals(backSeconds: Long, forwardSeconds: Long)
}
