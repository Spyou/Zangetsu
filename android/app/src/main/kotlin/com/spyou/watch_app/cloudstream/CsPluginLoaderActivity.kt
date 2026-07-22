package com.spyou.watch_app.cloudstream

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import java.io.File

/**
 * A thin, transparent [AppCompatActivity] used ONLY to (re)load CloudStream
 * plugins that cast their load context to an [AppCompatActivity].
 *
 * Our main screen is a FlutterActivity (a sibling of AppCompatActivity, not a
 * subclass), so loading with the Application context makes those plugins throw
 * `Application cannot be cast to AppCompatActivity` before they register a
 * source. This activity IS an AppCompatActivity, so loading the plugin against
 * `this` makes that cast succeed and the source registers.
 *
 * It's launched only for plugins that ALREADY hard-failed the normal load path
 * (see [PluginHost.pendingActivityLoads]); plugins that load fine never come
 * here. It finishes the instant loading completes, so it's an invisible blip.
 */
class CsPluginLoaderActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
        val paths = intent.getStringArrayExtra(EXTRA_PATHS) ?: emptyArray()
        val act = this
        // Load off the main thread (DexClassLoader + load() can be slow) but keep
        // this activity alive as the load context until it's done, then finish.
        Thread {
            for (p in paths) {
                runCatching { PluginHost.INSTANCE?.loadPlugin(File(p), act) }
            }
            runOnUiThread {
                onComplete?.invoke()
                finish()
                overridePendingTransition(0, 0)
            }
        }.start()
    }

    companion object {
        const val EXTRA_PATHS = "paths"

        /** Set by the caller before launch; invoked once loading finishes. Only one
         *  loader runs at a time (installs/loadAll are serialized on csExecutor). */
        @Volatile
        var onComplete: (() -> Unit)? = null
    }
}
