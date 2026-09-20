package com.spyou.watch_app

import android.app.Activity
import android.app.Application
import android.os.Bundle

/** Reports only our own visible activities; never inspects other apps. */
object BetaVisibility : Application.ActivityLifecycleCallbacks {
    private val resumed = java.util.Collections.newSetFromMap(java.util.WeakHashMap<Activity, Boolean>())
    private var installed = false
    val foreground get() = resumed.any { it is MainActivity || it is TvPlayerActivity }
    val playerForeground get() = resumed.any { it is TvPlayerActivity }
    fun install(app: Application) { if (!installed) { installed = true; app.registerActivityLifecycleCallbacks(this) } }
    override fun onActivityResumed(a: Activity) { resumed.add(a) }
    override fun onActivityPaused(a: Activity) { resumed.remove(a) }
    override fun onActivityDestroyed(a: Activity) { resumed.remove(a) }
    override fun onActivityCreated(a: Activity, b: Bundle?) {}
    override fun onActivityStarted(a: Activity) {}
    override fun onActivityStopped(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
}
