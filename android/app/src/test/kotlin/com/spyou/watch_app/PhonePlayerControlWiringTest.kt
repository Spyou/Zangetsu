package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
class PhonePlayerControlWiringTest {
    @Test fun `saved placement moves the working speed action into the top row`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_CONTROLS,
                """{"top":["speed"],"left":["sources","more"],"right":["episodes","rotate","fit"]}""")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        val top = activity.findViewById<ViewGroup>(R.id.fullscreen_top_actions)
        assertEquals(R.id.quick_speed, top.getChildAt(0).id)
        activity.findViewById<View>(R.id.quick_speed).performClick()
        assertTrue(ShadowDialog.getLatestDialog().isShowing)
        ShadowDialog.getLatestDialog().dismiss()
        assertTrue(activity.findViewById<View>(R.id.quick_more).hasOnClickListeners())
        assertTrue(activity.findViewById<View>(R.id.btn_controls_settings).hasOnClickListeners())
        controller.pause().stop().destroy()
    }

    @Test fun `lock has a working unlock control and Back unlocks before exiting`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        activity.findViewById<View>(R.id.btn_controls_lock).performClick()
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.btn_controls_unlock).visibility)
        assertEquals(View.GONE, activity.findViewById<View>(R.id.controls).visibility)
        activity.onBackPressed()
        assertEquals(View.GONE, activity.findViewById<View>(R.id.btn_controls_unlock).visibility)
        assertFalse(activity.isFinishing)
        activity.findViewById<View>(R.id.btn_controls_lock).performClick()
        activity.findViewById<View>(R.id.btn_controls_unlock).performClick()
        assertEquals(View.GONE, activity.findViewById<View>(R.id.btn_controls_unlock).visibility)
        controller.pause().stop().destroy()
    }
}
