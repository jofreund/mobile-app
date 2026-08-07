package io.music_assistant.client.bridge

/** Swift-callable cancellation handle for a coroutine subscription started on its behalf. */
fun interface Cancellable {
    fun cancel()
}
