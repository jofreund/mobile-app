package io.music_assistant.client.settings

/**
 * When the iOS lock screen / Dynamic Island Live Activity should be on screen.
 *
 * iOS-only in effect — Android has no counterpart surface — but stored here with every other
 * preference so the persistence, the default and the key live in one place.
 */
enum class LiveActivityVisibility {
    /** Whenever the selected player has something loaded, playing or not. The historic behavior. */
    ALWAYS,

    /** Only while at least one player is actually playing; the activity ends when they all stop. */
    WHILE_PLAYING,
}
