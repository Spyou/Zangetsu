package com.spyou.watch_app

import android.app.Activity
import android.app.Application
import android.os.Bundle
/**
 * Reports only our own visible activities; never inspects other apps.
 * [CompanionReceiver] reads it to decide which remote commands (keys, phone keyboard) are allowed.
 */
object CompanionVisibility : Application.ActivityLifecycleCallbacks {
    /** Our currently resumed activities; weak keys so a leaked reference cannot keep one alive. */
    private val resumed = java.util.Collections.newSetFromMap(java.util.WeakHashMap<Activity, Boolean>())
    private var installed = false
    /** True while the Zangetsu app or its TV player is on screen. */
    val foreground get() = resumed.any { it is MainActivity || it is TvPlayerActivity }
    /** True while the TV player is on screen (the phone keyboard is then refused). */
    val playerForeground get() = resumed.any { it is TvPlayerActivity }
    /** Registers one process-wide observer without inspecting other applications. */
    fun install(app: Application) { if (!installed) { installed = true; app.registerActivityLifecycleCallbacks(this) } }
    // Only resume/pause/destroy matter; the other lifecycle callbacks are intentionally empty.
    override fun onActivityResumed(a: Activity) { resumed.add(a) }
    override fun onActivityPaused(a: Activity) { resumed.remove(a) }
    override fun onActivityDestroyed(a: Activity) { resumed.remove(a) }
    override fun onActivityCreated(a: Activity, b: Bundle?) {}
    override fun onActivityStarted(a: Activity) {}
    override fun onActivityStopped(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
}
