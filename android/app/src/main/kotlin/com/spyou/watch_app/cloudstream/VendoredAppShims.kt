package com.lagradost.cloudstream3

import android.content.Context
import com.lagradost.cloudstream3.utils.DataStore
import com.lagradost.cloudstream3.utils.Event

/**
 * Clean-room shims for two CloudStream *app-module* classes many plugins
 * reference but that aren't in the bundled `:library` artifact — so those
 * plugins throw NoClassDefFoundError on load and fail to install.
 *
 * Both just re-expose the small companion surface plugins touch, delegating to
 * the existing [CloudStreamApp] / [DataStore]. Additive: nothing in this app or
 * any currently-working plugin references them, so this can't affect existing
 * sources — it only lets previously-failing plugins load.
 */
class AcraApplication {
    companion object {
        // `val context` → getter `getContext()`, the shape plugins call.
        val context: Context? get() = CloudStreamApp.getContext()

        fun <T> setKey(path: String, value: T) = CloudStreamApp.setKey(path, value)
        fun <T> setKey(folder: String, path: String, value: T) =
            CloudStreamApp.setKey(DataStore.getFolderName(folder, path), value)

        fun <T> getKey(path: String): T? = CloudStreamApp.getKey(path)
        fun <T> getKey(path: String, defVal: T?): T? = CloudStreamApp.getKey(path, defVal)

        fun removeKey(path: String) = CloudStreamApp.removeKey(path)
        fun removeKeys(folder: String): Int {
            val ctx = CloudStreamApp.getContext() ?: return 0
            return with(DataStore) { ctx.removeKeys(folder) }
        }
    }
}

/**
 * Shim for CloudStream's `MainActivity`, whose companion exposes app lifecycle
 * [Event]s that plugins subscribe to (e.g. run setup `afterPluginsLoadedEvent`).
 * Names/types mirror upstream so plugins link. The events are inert here (never
 * fired) — providers register in `load()`; these hooks are optional.
 */
class MainActivity {
    companion object {
        val afterPluginsLoadedEvent = Event<Boolean>()
        val mainPluginsLoadedEvent = Event<Boolean>()
        val afterRepositoryLoadedEvent = Event<Boolean>()
        val bookmarksUpdatedEvent = Event<Boolean>()
        val reloadHomeEvent = Event<Boolean>()
        val reloadLibraryEvent = Event<Boolean>()
        val reloadAccountEvent = Event<Boolean>()
    }
}
