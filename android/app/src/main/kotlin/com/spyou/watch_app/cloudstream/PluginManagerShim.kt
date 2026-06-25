package com.lagradost.cloudstream3.plugins

/**
 * Clean-room stand-ins for CloudStream's app-module `PluginManager` + `PluginData`.
 *
 * The bundled CloudStream *library* ships `BasePlugin`/`Plugin` but NOT the
 * app-module `PluginManager`. Plugins like StremioX call
 * `PluginManager.getPluginsOnline()` / `unloadPlugin()` inside their `reload()`
 * to register saved sub-providers (e.g. an added Stremio addon as its own
 * source). Without these classes `reload()` throws `NoClassDefFoundError`, is
 * swallowed, and the addon never registers — so it can't be searched or played.
 *
 * We report NO online plugins (so a reload takes the "register this addon" path
 * rather than trying to unload an existing one) and make unload a no-op.
 */
data class PluginData(
    val internalName: String,
    val isOnline: Boolean = false,
    val filePath: String = "",
    val url: String? = null,
    val version: Int = 1,
)

object PluginManager {
    fun getPluginsOnline(): Array<PluginData> = emptyArray()

    fun getPluginsLocal(): Array<PluginData> = emptyArray()

    fun unloadPlugin(absolutePath: String) {}
}
