package com.lagradost.cloudstream3.ui.settings.extensions

/**
 * App-internal CloudStream class, NOT shipped in the `library` artifact we
 * bundle. Some plugins — notably "mega repo" plugins that add a batch of
 * repositories on load — reference it, so we vendor a compatible shape here
 * (same pattern as [com.lagradost.cloudstream3.ui.settings.Globals]).
 *
 * Only the members those plugins touch are provided: the (name, url) and
 * (name, url, third) constructors and the generated getters.
 */
data class RepositoryData(
    val name: String,
    val url: String,
    val iconUrl: String? = null,
) {
    constructor(name: String, url: String) : this(name, url, null)
}
