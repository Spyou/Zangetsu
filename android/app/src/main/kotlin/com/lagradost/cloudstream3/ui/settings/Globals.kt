package com.lagradost.cloudstream3.ui.settings

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build

/**
 * Vendored subset of CloudStream's `ui.settings.Globals` for the Zangetsu
 * plugin host.
 *
 * The upstream class lives in the full CloudStream *app*, NOT in the
 * `com.github.recloudstream.cloudstream:library` artifact we compile the
 * runtime against. Some extensions reference it — e.g. Telegram/Discord promo
 * popups invoked from `getMainPage()` / `loadLinks()` — so DexClassLoading them
 * against our subset threw `NoClassDefFoundError: …ui/settings/Globals` and the
 * whole home feed / link resolution came back empty ("Couldn't load"), even
 * though search and load worked.
 *
 * This restores the same public surface (`PHONE` / `TV` / `EMULATOR` +
 * `isLayout`) minus the app-only `R.string.app_layout_key` / SharedPreferences
 * lookup the original used.
 *
 * `layoutId` defaults to [TV] on purpose: those promo popups are conventionally
 * guarded with `if (isLayout(TV)) return`, so reporting TV short-circuits them
 * in our headless host (there is no CloudStream Activity to show a dialog on),
 * letting the data methods run to completion. Content methods don't branch on
 * layout, so this has no effect on results.
 */
object Globals {
    @Suppress("unused")
    var beneneCount = 0

    const val PHONE: Int = 0b001
    const val TV: Int = 0b010
    const val EMULATOR: Int = 0b100

    // Default to TV so promo-popup guards short-circuit (see class note).
    private var layoutId = TV

    private fun Context.isAutoTv(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager?
        val model = Build.MODEL.lowercase()
        return uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            Build.MODEL.contains("AFT") ||
            model.contains("firestick") ||
            model.contains("fire tv") ||
            model.contains("chromecast")
    }

    /** Optional: let the host refine the layout from a real context. Unused by
     *  extensions (they only call [isLayout]); kept for API compatibility. */
    fun Context.updateTv() {
        layoutId = if (isAutoTv()) TV else PHONE
    }

    /** Returns true if the current orientation is landscape. */
    fun isLandscape(): Boolean =
        isLayout(TV or EMULATOR) ||
            Resources.getSystem().configuration.orientation ==
            Configuration.ORIENTATION_LANDSCAPE

    /**
     * Returns true if the current layout matches any of [flags]
     * (valid flags: [PHONE], [TV], [EMULATOR]).
     */
    fun isLayout(flags: Int): Boolean = (layoutId and flags) != 0
}
