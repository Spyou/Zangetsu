package com.spyou.watch_app

import androidx.media3.exoplayer.DefaultLoadControl
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhonePlayerBufferTest {
    private val mb = 1024 * 1024

    @Test
    fun `high buffer leaves room in a 256 MB heap`() {
        val control = BufferPresets.loadControl(50_000, 120_000, 512 * mb, 30_000,
            maxHeapBytes = 256L * mb)
        assertEquals(64 * mb, field(control, "targetBufferBytesOverwrite"))
        assertEquals(10_000_000L, field(control, "backBufferDurationUs"))
        assertEquals(false, field(control, "prioritizeTimeOverSizeThresholds"))
        assertEquals(120_000_000L, field(control, "maxBufferUs"))
    }

    @Test
    fun `smaller settings and disabled back buffer are preserved`() {
        val control = BufferPresets.loadControl(15_000, 15_000, 32 * mb, 0,
            maxHeapBytes = 256L * mb)
        assertEquals(32 * mb, field(control, "targetBufferBytesOverwrite"))
        assertEquals(0L, field(control, "backBufferDurationUs"))
    }

    @Test
    fun `missing byte setting still receives a safe limit`() {
        val control = BufferPresets.loadControl(0, 0, 0, 0,
            maxHeapBytes = 128L * mb)
        assertEquals(32 * mb, field(control, "targetBufferBytesOverwrite"))
    }

    @Test
    fun `TV and platform view retain existing settings`() {
        val control = BufferPresets.loadControl(50_000, 120_000, 512 * mb, 30_000)
        assertEquals(512 * mb, field(control, "targetBufferBytesOverwrite"))
        assertEquals(30_000_000L, field(control, "backBufferDurationUs"))
    }

    private fun field(control: Any, name: String): Any =
        DefaultLoadControl::class.java.getDeclaredField(name).apply {
            isAccessible = true
        }.get(control)!!
}
