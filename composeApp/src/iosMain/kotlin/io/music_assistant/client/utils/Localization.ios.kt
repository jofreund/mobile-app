package io.music_assistant.client.utils

import platform.Foundation.NSBundle

/**
 * Resolves against the app bundle, which is where the `.xcstrings` catalog compiles to. The
 * framework is statically linked into the app, so `mainBundle` is the right bundle to ask —
 * there is no separate framework bundle to look in.
 */
actual fun localizedString(key: String): String =
    NSBundle.mainBundle.localizedStringForKey(key, value = null, table = null)
