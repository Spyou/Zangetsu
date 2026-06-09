package com.lagradost.cloudstream3

import android.content.Context

/**
 * Clean-room stand-in for CloudStream's app-module `CloudStreamApp`.
 *
 * The bundled CloudStream *library* doesn't ship it, but newer `.cs3` plugins
 * reference `com.lagradost.cloudstream3.CloudStreamApp` for the global app
 * context + a key/value settings store (e.g. AnimePahe reads/writes its server
 * preference). Without it those plugins throw `NoClassDefFoundError` on load and
 * never install. We expose the small Companion surface they use, backed by a
 * SharedPreferences so settings persist.
 *
 * Plugins call the Companion instance methods (Kotlin generates
 * `CloudStreamApp.Companion` + `CloudStreamApp$Companion.<method>`), so these
 * stay as plain companion funcs (no @JvmStatic) to match that shape.
 */
class CloudStreamApp {
    companion object {
        @Volatile
        private var appContext: Context? = null

        /** Set once at startup (see PluginHost) before any plugin loads. */
        fun setContext(context: Context) {
            appContext = context.applicationContext
        }

        fun getContext(): Context? = appContext

        // Storage is delegated to DataStore so the value written here round-trips
        // with the plugins' inlined getKey (which reads via DataStore too).
        fun setKey(path: String, value: Any?) =
            com.lagradost.cloudstream3.utils.DataStore.setKey(path, value)

        fun <T> getKey(path: String): T? = getKey(path, null)

        @Suppress("UNCHECKED_CAST")
        fun <T> getKey(path: String, defVal: T?): T? =
            (com.lagradost.cloudstream3.utils.DataStore.getKey(path, Any::class.java) as? T)
                ?: defVal

        fun removeKey(path: String) {
            appContext?.let {
                com.lagradost.cloudstream3.utils.DataStore.getSharedPrefs(it)
                    .edit().remove(path).apply()
            }
        }
    }
}
