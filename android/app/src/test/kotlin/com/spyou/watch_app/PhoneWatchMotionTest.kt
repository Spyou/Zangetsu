package com.spyou.watch_app

import android.app.Activity
import android.os.SystemClock
import android.view.MotionEvent
import android.widget.FrameLayout
import android.widget.TextView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhoneWatchMotionTest {
    @Test @Config(qualifiers = "port")
    fun `press feedback keeps native clicks immediate`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            val activity = controller.get()
            var clicks = 0
            val button = TextView(activity).apply { setOnClickListener { clicks++ } }
            activity.setContentView(FrameLayout(activity).apply {
                addView(button, FrameLayout.LayoutParams(100, 100))
            })
            button.layout(0, 0, 100, 100)
            PhoneWatchMotion.press(button)
            val now = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(now, now, action, 50f, 50f, 0)
                button.dispatchTouchEvent(event)
                event.recycle()
            }
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            assertEquals(1, clicks)
        } finally { controller.pause().stop().destroy() }
    }

    @Test @Config(qualifiers = "land")
    fun `landscape receives no new text motion`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            val view = TextView(controller.get())
            controller.get().setContentView(view)
            assertFalse(PhoneWatchMotion.enabled(view))
            PhoneWatchMotion.text(view, "New episode")
            assertEquals("New episode", view.text.toString())
            assertEquals(1f, view.alpha, 0f)
            assertEquals(0f, view.translationY, 0f)
        } finally { controller.pause().stop().destroy() }
    }
}
