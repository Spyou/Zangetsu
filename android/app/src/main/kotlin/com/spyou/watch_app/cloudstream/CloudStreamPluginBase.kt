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
    /** Overridden by plugins; called once after the plugin is instantiated. */
    open fun load(context: Context) {}

    var resources: Resources? = null
    var needsResources: Boolean = false
    var openSettings: ((context: Context) -> Unit)? = null
}
