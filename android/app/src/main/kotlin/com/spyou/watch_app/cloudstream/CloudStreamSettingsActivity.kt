package com.spyou.watch_app.cloudstream

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentManager

/**
 * A thin, transparent [AppCompatActivity] that hosts a CloudStream plugin's OWN
 * settings UI.
 *
 * Plugins expose settings via `Plugin.openSettings(Context)`. There are two shapes:
 *  - Fragment/BottomSheet plugins (e.g. AnimePahe, StremioX) cast the Context to
 *    [AppCompatActivity] and show a `BottomSheetDialogFragment` on
 *    `supportFragmentManager`.
 *  - Plain-dialog plugins (e.g. CineStream) show an `android.app.AlertDialog`
 *    straight on this activity's window — NO fragment is added.
 *
 * Our main screen is a FlutterActivity (NOT an AppCompatActivity), so we launch
 * this dedicated activity, hand it to the plugin, and finish as soon as the
 * sheet/dialog is dismissed — leaving the user back where they were.
 */
class CloudStreamSettingsActivity : AppCompatActivity() {

    // A plain dialog (AlertDialog) grabs window focus off this activity; used to
    // detect its dismissal for the non-fragment path (see onWindowFocusChanged).
    private var dialogTookFocus = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val apiName = intent.getStringExtra(EXTRA_API_NAME)
        if (apiName == null) {
            finish()
            return
        }

        if (savedInstanceState == null) {
            // Fragment/BottomSheet plugins: finish once their sheet fragment goes
            // away (only on a fresh launch, so a config change doesn't re-open it).
            supportFragmentManager.registerFragmentLifecycleCallbacks(
                object : FragmentManager.FragmentLifecycleCallbacks() {
                    override fun onFragmentViewDestroyed(fm: FragmentManager, f: Fragment) {
                        if (fm.fragments.isEmpty()) finish()
                    }
                },
                false,
            )
            // openSettings binds the plugin against THIS activity (an
            // AppCompatActivity), so plugins that capture the activity at load
            // time (e.g. StremioX) can actually show their sheet.
            val shown = PluginHost.INSTANCE?.openSettings(apiName, this) ?: false
            // Nothing got shown (no settings / failed) → don't leave a blank
            // transparent activity hanging.
            if (!shown) finish()
            // NOTE: intentionally NO postDelayed "finish if no fragment" here.
            // Plain-dialog plugins (CineStream) add no fragment, so that check
            // fired while their AlertDialog was still up and slammed it shut
            // instantly. Those are handled by onWindowFocusChanged below.
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Only for plain-dialog plugins: while their AlertDialog is up, this
        // activity has NO window focus; when the dialog is dismissed, focus comes
        // back — our cue to leave. Gated on an empty fragment manager so
        // fragment/BottomSheet plugins keep using their own lifecycle finish above
        // (their sheet keeps a fragment present, so this never fires for them).
        if (!hasFocus) {
            dialogTookFocus = true
            return
        }
        if (dialogTookFocus && supportFragmentManager.fragments.isEmpty()) finish()
    }

    companion object {
        const val EXTRA_API_NAME = "apiName"
    }
}
