package com.lagradost.cloudstream3.utils

/**
 * Clean-room copies of CloudStream's [Event] / [EmptyEvent]. These live in
 * CloudStream's *app* module, not the published `:library` artifact this app
 * bundles — so plugins that subscribe to app lifecycle events (via
 * [com.lagradost.cloudstream3.MainActivity]'s companion) reference classes the
 * loader can't find and fail to install with a NoClassDefFoundError.
 *
 * Providing them (byte-for-byte with upstream behaviour) lets those plugins load.
 * They're inert here — nothing in this app fires the events — which is fine:
 * providers do their real registration in `load()`, and the events are optional
 * post-load hooks. NOTHING existing references these, so adding them is additive
 * and cannot affect any source that already works.
 */
class Event<T> {
    private val observers = mutableSetOf<(T) -> Unit>()

    val size: Int get() = observers.size

    operator fun plusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.add(observer) }
    }

    operator fun minusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.remove(observer) }
    }

    operator fun invoke(value: T) {
        synchronized(observers) { for (observer in observers) observer(value) }
    }
}

class EmptyEvent {
    private val observers = mutableSetOf<Runnable>()

    val size: Int get() = observers.size

    operator fun plusAssign(observer: Runnable) {
        synchronized(observers) { observers.add(observer) }
    }

    operator fun minusAssign(observer: Runnable) {
        synchronized(observers) { observers.remove(observer) }
    }

    operator fun invoke() {
        synchronized(observers) { for (observer in observers) observer.run() }
    }
}
