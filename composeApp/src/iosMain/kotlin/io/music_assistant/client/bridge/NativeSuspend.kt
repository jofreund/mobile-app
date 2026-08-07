package io.music_assistant.client.bridge

import co.touchlab.kermit.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

private val log = Logger.withTag("NativeSuspend")

/**
 * Generic Swift-callable wrapper over a one-shot suspend computation, replacing
 * the hand-written `launchFetch(label, completion, fetch)` helper `KmpHelper`
 * used to duplicate per call site.
 *
 * Deliberately carries no built-in timeout — the original `KmpHelper` fixed
 * every fetch to a single 5s `FETCH_TIMEOUT_MS` tuned for CarPlay round trips,
 * and the Phase A spike found that too tight for ordinary UI use (a real
 * album's track fetch took 5.1s and surfaced as a false "not connected").
 * Callers that want a budget wrap [block] in `withTimeoutOrNull(ms) { … }`
 * themselves when constructing this, so the budget is a visible, per-fetcher
 * decision rather than a silent global.
 */
class NativeSuspend<T : Any>(
    private val scope: CoroutineScope,
    private val block: suspend () -> T?,
) {
    /**
     * Starts [block]. [onResult] fires exactly once with the result (`null`
     * meaning the block itself returned null — e.g. a caller-applied timeout
     * expired), unless cancelled first via the returned handle, in which case
     * neither callback fires.
     */
    fun invoke(onResult: (T?) -> Unit, onError: (Throwable) -> Unit): Cancellable {
        val job = scope.launch {
            try {
                onResult(block())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                log.w(e) { "suspend block failed" }
                onError(e)
            }
        }
        return Cancellable { job.cancel() }
    }
}
