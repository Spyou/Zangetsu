package com.lagradost.cloudstream3.plugins

import android.content.Context
import android.content.res.Resources

/**
 * Clean-room stand-in for CloudStream's app-module `Plugin` class.
 *
 * The bundled CloudStream *library* ships only `BasePlugin`; `.cs3` plugins are
 * compiled against `com.lagradost.cloudstream3.plugins.Plugin`, so we provide a
 * binary-compatible base here for them to link against at load time (the
 * DexClassLoader's parent — our app classloader — resolves it).
 *
 * Mirrors only the public surface plugins use (see CloudStream `Plugin.kt`).
 * Extend as on-device testing reveals plugins referencing more members.
 */
abstract class Plugin : BasePlugin() {
    /**
     * Called once after the plugin is instantiated. Plugins override EITHER this
     * (Context) overload OR the no-arg [BasePlugin.load]. CloudStream's real
     * `Plugin.load(Context)` default delegates to `load()`, so a plugin that
     * only overrides the no-arg `load()` (e.g. AnimePahe, which registers its
     * MainAPI there) still runs. Our stub must do the same or those plugins
     * load but register nothing ("won't install").
     */
    open fun load(context: Context) {
        load()
    }

    var resources: Resources? = null
    var needsResources: Boolean = false
    var openSettings: ((context: Context) -> Unit)? = null
}
