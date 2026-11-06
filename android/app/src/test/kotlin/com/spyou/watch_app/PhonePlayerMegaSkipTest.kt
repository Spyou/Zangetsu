package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
class PhonePlayerMegaSkipTest {
    @Test fun `skip uses the selected amount and stops at the end`() {
        assertEquals(95_000L, PhonePlayerActivity.megaSkipTarget(10_000, 300_000, 85))
        assertEquals(40_000L, PhonePlayerActivity.megaSkipTarget(10_000, 300_000, 30))
        assertEquals(100_000L, PhonePlayerActivity.megaSkipTarget(90_000, 100_000, 85))
        assertEquals(Long.MAX_VALUE, PhonePlayerActivity.megaSkipTarget(Long.MAX_VALUE - 10, Long.MAX_VALUE, 85))
    }
    @Test fun `unknown duration cannot trigger a bogus jump`() {
        assertNull(PhonePlayerActivity.megaSkipTarget(10_000, 0, 85))
        assertNull(PhonePlayerActivity.megaSkipTarget(10_000, -1, 85))
        assertEquals(5_000L, PhonePlayerActivity.megaSkipTarget(-100, 300_000, 0))
        assertEquals(180_000L, PhonePlayerActivity.megaSkipTarget(0, 300_000, 999))
    }
    @Test fun `fullscreen timestamp is left aligned with a wired 85 second pill on the right`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        val time = activity.findViewById<TextView>(R.id.time_chip)
        val row = time.parent as LinearLayout
        assertEquals(Gravity.START, row.gravity and Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK)
        assertEquals(time, row.getChildAt(0))
        val skip = row.findViewById<View>(R.id.quick_mega_skip)
        assertEquals(View.VISIBLE, skip.visibility)
        assertTrue(skip.hasOnClickListeners())
        assertEquals("+85s", ((skip as LinearLayout).getChildAt(1) as TextView).text.toString())
        assertEquals(skip, row.getChildAt(row.childCount - 1))
        controller.pause().stop().destroy()
    }
    @Test fun `disabled skip leaves no button and does not recenter the time`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_MEGA_SKIP, false)
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        assertNull(activity.findViewById<View>(R.id.quick_mega_skip))
        val row = activity.findViewById<TextView>(R.id.time_chip).parent as LinearLayout
        assertEquals(Gravity.START, row.gravity and Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK)
        controller.pause().stop().destroy()
    }
}
