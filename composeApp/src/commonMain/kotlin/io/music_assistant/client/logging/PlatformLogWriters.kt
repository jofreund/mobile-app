package io.music_assistant.client.logging

import co.touchlab.kermit.LogWriter

/**
 * Platform console [LogWriter]s, registered alongside [InMemoryLogWriter] in `AppGraph.start`.
 *
 * Each platform owns its console sink so common code can register writers without
 * inheriting Kermit's default (which on iOS redacts every interpolated value).
 */
expect fun platformLogWriters(): List<LogWriter>
