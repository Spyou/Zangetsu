package ani.dantotsu.util

import android.util.Log

/**
 * Minimal logging bridge used by vendored Aniyomi runtime classes.
 * Delegates to android.util.Log so those classes compile without pulling
 * in the full Dantotsu application infrastructure.
 */
object Logger {
    private const val TAG = "Aniyomi"

    fun log(message: String) {
        Log.d(TAG, message)
    }

    fun log(level: Int, message: String, tag: String = TAG) {
        Log.println(level, tag, message)
    }

    fun log(e: Exception) {
        Log.e(TAG, e.message ?: e.toString(), e)
    }

    fun log(e: Throwable) {
        Log.e(TAG, e.message ?: e.toString(), e)
    }
}
