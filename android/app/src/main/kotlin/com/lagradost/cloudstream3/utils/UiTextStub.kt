package com.lagradost.cloudstream3.utils

/**
 * Clean-room stub of CloudStream's [UiText] (real is a sealed class in the app
 * module, not in the bundled `:library`). A bare sealed class is useless as a
 * link stub, so this is a plain open class. `asString` takes a nullable-defaulted
 * Context so both `asString()` and `asString(ctx)` link; it returns "".
 * Referenced by SyncAPI.LibraryList/Page and by plugins.
 */
open class UiText {
    fun asString(context: android.content.Context? = null): String = ""
    fun asStringNull(context: android.content.Context? = null): String? = null
}
