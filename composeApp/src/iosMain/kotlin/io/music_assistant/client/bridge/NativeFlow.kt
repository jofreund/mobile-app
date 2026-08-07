package io.music_assistant.client.bridge

import co.touchlab.kermit.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

private val log = Logger.withTag("NativeFlow")

/**
 * Generic Swift-callable wrapper over a [Flow], replacing the one-off
 * `observeX(onChanged:) -> Cancellable` functions that used to be hand-written
 * per concern in `KmpHelper`. Kotlin/Native exports generic classes to
 * Objective-C/Swift with lightweight generics (bounded to [T] : Any, i.e.
 * reference types — primitives arrive boxed, e.g. `KotlinBoolean`), so this
 * stays fully typed on the Swift side rather than degrading to `id`/`AnyObject`.
 *
 * [scope] is caller-supplied rather than a shared app-wide scope so a bridge
 * facade can tie subscription lifetime to something narrower when it matters
 * (e.g. a screen-scoped Koin scope); most callers pass a `Dispatchers.Main`
 * scope that outlives the app.
 */
class NativeFlow<T : Any>(
    private val flow: Flow<T>,
    private val scope: CoroutineScope,
) {
    /**
     * Subscribes on the main thread; [onEach] fires for every emission,
     * [onError] fires at most once (a Flow that throws is terminated).
     * Cancelling the returned handle is the only way to stop collection —
     * Swift must retain it for the subscription's intended lifetime and
     * call `cancel()` in `deinit`/`stopLoading`/etc., mirroring the existing
     * `Cancellable` contract `NowPlayingCoordinator.swift` already uses.
     */
    fun subscribe(onEach: (T) -> Unit, onError: (Throwable) -> Unit): Cancellable {
        val job = scope.launch {
            try {
                flow.collect { onEach(it) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                log.w(e) { "flow collection failed" }
                onError(e)
            }
        }
        return Cancellable { job.cancel() }
    }
}

/**
 * [NativeFlow] specialization for [StateFlow]: exposes the current [value]
 * synchronously (no round trip through Swift concurrency needed for an
 * initial read) in addition to [subscribe], which — per [StateFlow]'s
 * conflated-replay contract — always fires once immediately with the current
 * value before tracking further changes. There is no error channel: a
 * [StateFlow] does not terminate on failure the way a general [Flow] can.
 */
class NativeStateFlow<T : Any>(
    private val flow: StateFlow<T>,
    private val scope: CoroutineScope,
) {
    val value: T get() = flow.value

    fun subscribe(onEach: (T) -> Unit): Cancellable {
        val job = scope.launch {
            flow.collect { onEach(it) }
        }
        return Cancellable { job.cancel() }
    }
}
