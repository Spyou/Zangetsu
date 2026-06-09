package com.spyou.watch_app.cloudstream

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentManager

/**
 * A thin, transparent [AppCompatActivity] that hosts a CloudStream plugin's OWN
 * settings UI.
 *
 * Plugins (e.g. AnimePahe) expose settings via `Plugin.openSettings(Context)`,
 * and inside it they cast the Context to [AppCompatActivity] and show a
 * `BottomSheetDialogFragment` on `supportFragmentManager`. Our main screen is a
 * FlutterActivity (NOT an AppCompatActivity), so we launch this dedicated
 * activity, hand it to the plugin, and finish as soon as the sheet/dialog is
 * dismissed — leaving the user back where they were.
 */
class CloudStreamSettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val apiName = intent.getStringExtra(EXTRA_API_NAME)
        val opener = apiName?.let { PluginHost.INSTANCE?.settingsInvokerFor(it) }
        if (opener == null) {
            finish()
            return
        }

        // Finish once the plugin's dialog/sheet goes away (only on a real
        // relaunch, i.e. the user came from a fresh launch — savedInstanceState
        // null — so we don't re-open it after a config change).
        if (savedInstanceState == null) {
            supportFragmentManager.registerFragmentLifecycleCallbacks(
                object : FragmentManager.FragmentLifecycleCallbacks() {
                    override fun onFragmentViewDestroyed(fm: FragmentManager, f: Fragment) {
                        // The sheet was dismissed; nothing left to show → leave.
                        if (fm.fragments.isEmpty()) finish()
                    }
                },
                false,
            )
            try {
                opener(this)
            } catch (t: Throwable) {
                finish()
            }
        }
    }

    companion object {
        const val EXTRA_API_NAME = "apiName"
    }
}
