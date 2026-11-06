package com.spyou.watch_app

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
class PhonePlayerFullscreenStyleTest {
    @Test
    fun `fullscreen keeps transparent chrome and both translucent action groups`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = LayoutInflater.from(context).inflate(R.layout.phone_player, null)
        assertNull(root.findViewById<View>(R.id.top_bar).background)
        assertNotNull(root.findViewById<View>(R.id.time_chip))
        assertNotNull(root.findViewById<View>(R.id.transport_row))
        val left = root.findViewById<ViewGroup>(R.id.fullscreen_actions_left)
        val right = root.findViewById<ViewGroup>(R.id.fullscreen_actions_right)
        assertEquals(5, left.childCount)
        assertEquals(3, right.childCount)
        assertEquals(0x4D000000, (left.background as GradientDrawable).color!!.defaultColor)
        assertEquals(0x4D000000, (right.background as GradientDrawable).color!!.defaultColor)
        val play = root.findViewById<View>(R.id.btn_play)
        assertEquals(0x73000000, (play.background as GradientDrawable).color!!.defaultColor)
        assertEquals((58 * context.resources.displayMetrics.density + 0.5f).toInt(),
            (play.parent as View).layoutParams.width)
        for (id in listOf(R.id.btn_back, R.id.btn_more, R.id.btn_previous, R.id.btn_next,
            R.id.quick_sources, R.id.quick_tracks, R.id.quick_quality, R.id.quick_speed,
            R.id.quick_episodes, R.id.quick_display, R.id.btn_rotate, R.id.loading)) {
            assertNotNull("Missing existing fullscreen action $id", root.findViewById<View>(id))
        }
    }
}
