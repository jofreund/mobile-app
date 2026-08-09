package io.music_assistant.client.utils

/**
 * Look up a localized string by key, for the handful of non-UI places that legitimately need
 * one in Kotlin.
 *
 * This exists because compose-resources (`Res.string` + `getString`) was the shared core's only
 * string source, and keeping it meant keeping the whole Compose dependency for the sake of a
 * couple of messages — the last thing standing between Phase F and actually deleting Compose.
 * The catalog moved to `iosApp/iosApp/Localizable.xcstrings` during Phase D and every key came
 * with it, so this is a redirect to the same translations, not a second string store.
 *
 * Prefer `String(localized:)` in Swift. Reach for this only when the string is produced by
 * Kotlin and consumed as plain text — `ErrorMessageBus` messages, which arrive already
 * formatted because their other source is server error text, and `CarPlayStrings`, whose
 * template titles must be resolved before the first CarPlay template is built.
 *
 * Missing keys resolve to the key itself rather than throwing, matching the platform's own
 * behaviour.
 */
expect fun localizedString(key: String): String
