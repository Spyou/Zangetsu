package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.SeekBar
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
class PhonePlayerSeekGeometryTest {
    @Test fun `fullscreen seek spacing and thumb edges match the compact player chrome`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        try {
            val activity = controller.get()
            val seek = activity.findViewById<SeekBar>(R.id.seek)
            fun dp(n: Int) = (n * activity.resources.displayMetrics.density + 0.5f).toInt()
            assertEquals(dp(26), seek.layoutParams.height)
            assertFalse(seek.splitTrack)
            assertEquals(seek.thumb.intrinsicWidth / 2, seek.paddingLeft)
            assertEquals(seek.thumb.intrinsicWidth / 2, seek.paddingRight)
            assertEquals(seek.thumb.intrinsicWidth / 2, seek.thumbOffset)
            seek.measure(View.MeasureSpec.makeMeasureSpec(dp(400), View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(dp(26), View.MeasureSpec.EXACTLY))
            seek.layout(0, 0, dp(400), dp(26))
            for (progress in listOf(0, 1, 500, 999, 1000)) {
                seek.progress = progress
                val origin = seek.paddingLeft - seek.thumbOffset
                assertTrue("Thumb clipped at start for $progress", seek.thumb.bounds.left + origin >= 0)
                assertTrue("Thumb clipped at end for $progress", seek.thumb.bounds.right + origin <= seek.width)
            }
        } finally { controller.pause().stop().destroy() }
    }
}
