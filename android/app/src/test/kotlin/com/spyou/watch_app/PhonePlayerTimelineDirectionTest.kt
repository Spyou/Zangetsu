package com.spyou.watch_app

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.widget.SeekBar
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhonePlayerTimelineDirectionTest {
    @Test
    @Config(qualifiers = "ar-rEG-ldrtl-port")
    fun `Arabic portrait keeps playback time left to right`() = assertTimelineDirection(View.LAYOUT_DIRECTION_RTL)

    @Test
    @Config(qualifiers = "ar-rEG-ldrtl-land")
    fun `Arabic fullscreen keeps playback time left to right`() = assertTimelineDirection(View.LAYOUT_DIRECTION_RTL)

    @Test
    @Config(qualifiers = "en-rUS-ldltr-land")
    fun `English fullscreen keeps its existing timeline direction`() = assertTimelineDirection(View.LAYOUT_DIRECTION_LTR)

    private fun assertTimelineDirection(appDirection: Int) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = LayoutInflater.from(context).inflate(R.layout.phone_player, null)
        root.layoutDirection = appDirection
        root.findViewById<View>(R.id.controls).visibility = View.VISIBLE
        val width = View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY)
        val height = View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY)
        root.measure(width, height)
        root.layout(0, 0, 1000, 600)
        val seek = root.findViewById<SeekBar>(R.id.seek)
        val time = root.findViewById<TextView>(R.id.time_chip)
        assertEquals(View.LAYOUT_DIRECTION_LTR, seek.layoutDirection)
        assertEquals(View.LAYOUT_DIRECTION_LTR, (time.parent as View).layoutDirection)
        assertEquals(1, time.layout.getParagraphDirection(0))
        assertEquals(appDirection, root.findViewById<View>(R.id.top_bar).layoutDirection)
    }
}
