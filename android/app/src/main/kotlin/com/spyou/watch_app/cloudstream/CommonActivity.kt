package com.lagradost.cloudstream3

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.widget.Toast

/**
 * Clean-room stand-in for CloudStream's app-module `CommonActivity`.
 *
 * The bundled CloudStream *library* doesn't ship it, but `.cs3` plugins call
 * `com.lagradost.cloudstream3.CommonActivity.showToast(...)` (e.g. StremioX after
 * deleting a saved link). Without this class the call throws
 * `NoClassDefFoundError` and crashes the whole app. We expose the toast surface
 * plugins use, shown via the current activity if one is registered, else the
 * global app context. Toasts are posted to the main thread so a plugin can call
 * showToast from anywhere.
 */
object CommonActivity {
    @Volatile
    var activity: Activity? = null

    fun setActivityInstance(newActivity: Activity?) {
        activity = newActivity
    }

    fun showToast(message: String?, duration: Int? = null) {
        val msg = message ?: return
        val ctx = activity ?: CloudStreamApp.getContext() ?: return
        val len = if (duration == Toast.LENGTH_LONG) Toast.LENGTH_LONG else Toast.LENGTH_SHORT
        Handler(Looper.getMainLooper()).post {
            try {
                Toast.makeText(ctx, msg, len).show()
            } catch (_: Throwable) {
            }
        }
    }

    fun showToast(act: Activity?, message: String?, duration: Int? = null) =
        showToast(message, duration)
}
