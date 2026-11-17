package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [29, 34])
class TvPlayerBufferTest {
    @Test
    fun `TV caps oversized buffers and bounds rewind memory`() {
        val control = control(Int.MAX_VALUE, 30_000)
        assertEquals(heapLimit(), field(control, "targetBufferBytesOverwrite"))
        assertEquals(false, field(control, "prioritizeTimeOverSizeThresholds"))
        assertEquals(10_000_000L, field(control, "backBufferDurationUs"))
        assertEquals(120_000_000L, field(control, "maxBufferUs"))
    }

    @Test
    fun `TV also bounds automatic buffers`() {
        assertEquals(heapLimit(), field(control(0, 0), "targetBufferBytesOverwrite"))
    }

    @Test
    fun `a 192 MB TV heap cannot request a 512 MB buffer`() {
        val mb = 1024 * 1024
        val control = BufferPresets.loadControl(
            50_000, 120_000, 512 * mb, 30_000, maxHeapBytes = 192L * mb,
        )
        assertEquals(48 * mb, field(control, "targetBufferBytesOverwrite"))
        assertEquals(false, field(control, "prioritizeTimeOverSizeThresholds"))
    }

    @Test
    fun `TV preserves smaller requested buffers and disabled rewind`() {
        val control = control(64 * 1024, 0)
        assertEquals(64 * 1024, field(control, "targetBufferBytesOverwrite"))
        assertEquals(0L, field(control, "backBufferDurationUs"))
    }

    private fun heapLimit() = (Runtime.getRuntime().maxMemory() / 4)
        .coerceIn(64 * 1024L, Int.MAX_VALUE.toLong()).toInt()

    private fun control(bytes: Int, backMs: Int): Any {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, TvPlayerActivity::class.java)
            .putExtra(TvPlayerActivity.EXTRA_BUF_MIN_MS, 50_000)
            .putExtra(TvPlayerActivity.EXTRA_BUF_MAX_MS, 120_000)
            .putExtra(TvPlayerActivity.EXTRA_BUF_BYTES, bytes)
            .putExtra(TvPlayerActivity.EXTRA_BUF_BACK_MS, backMs)
        val activity = Robolectric.buildActivity(TvPlayerActivity::class.java, intent).get()
        return TvPlayerActivity::class.java.getDeclaredMethod("loadControl").apply {
            isAccessible = true
        }.invoke(activity)!!
    }

    private fun field(control: Any, name: String): Any =
        DefaultLoadControl::class.java.getDeclaredField(name).apply {
            isAccessible = true
        }.get(control)!!
}
