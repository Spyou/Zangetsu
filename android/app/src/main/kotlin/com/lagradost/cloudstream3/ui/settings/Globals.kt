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
 * `layoutId` reports the REAL device, resolved once from the running context.
 *
 * It used to be hardcoded to [TV], to short-circuit promo popups guarded with
 * `if (isLayout(TV)) return` — there was no Activity to show a dialog on then,
 * so claiming to be a television kept the data methods running. That premise is
 * gone (MainActivity is a real AppCompatActivity now), and the lie turned out to
 * cost more than it saved: plugins gate REAL work on this too.
 *
 * CNC Verse's Netflix/Disney/Hotstar sources verify a session by opening
 * `net22.cc/verify2` in a browser — and `openInExternalBrowser` starts with an
 * `isLayout` check, because a TV has nowhere sensible to open one. Claiming TV
 * meant the plugin silently never verified, and NetMirror answered the
 * unverified client with a "Too Many Requests" placeholder VIDEO rather than an
 * error. Nothing failed anywhere; an advert just played instead of the film.
 *
 * So: tell the truth. A phone says PHONE and gets the phone behaviour a plugin
 * author intended, popups included; a TV still says TV and still short-circuits.
 */
object Globals {
    @Suppress("unused")
    var beneneCount = 0

    const val PHONE: Int = 0b001
    const val TV: Int = 0b010
    const val EMULATOR: Int = 0b100

    // TV until a real context says otherwise: [resolveFrom] runs at plugin-host
    // startup, and until it does, the old short-circuiting default is the safer
    // of the two — better to skip a popup than to pop one with no window.
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

    /** Set the layout from [context] — same detection the app's own `isTv`
     *  channel uses (UI mode + the leanback features), so the plugin host and
     *  the Flutter side can never disagree about what kind of device this is.
     *  Called once when the plugin host starts. Best-effort: on any failure the
     *  conservative TV default stands. */
    fun resolveFrom(context: Context) {
        layoutId = runCatching {
            val leanback = context.packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_LEANBACK,
            ) || context.packageManager.hasSystemFeature("android.software.leanback_only")
            if (context.isAutoTv() || leanback) TV else PHONE
        }.getOrDefault(TV)
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
