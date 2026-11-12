package com.spyou.watch_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhonePlaybackCacheTest {
    @Test fun `cache identity includes headers and never exposes signed URLs`() {
        val url = "https://test/video.mp4?token=secret"
        val first = PhonePlaybackCache.keyFor(url, mapOf("Authorization" to "Bearer one"))
        assertEquals(first, PhonePlaybackCache.keyFor(url, mapOf("authorization" to "Bearer one")))
        assertNotEquals(first, PhonePlaybackCache.keyFor(url, mapOf("Authorization" to "Bearer two")))
        assertNotEquals(first, PhonePlaybackCache.keyFor("https://test/other.mp4", emptyMap()))
        assertFalse(first.contains("secret"))
        assertEquals(64, first.length)
    }

    @Test fun `only remote direct video streams receive extra buffering`() {
        assertTrue(PhonePlaybackCache.supports("https://test/a.mp4", null))
        assertTrue(PhonePlaybackCache.supports("http://test/stream", "video/x-matroska"))
        assertFalse(PhonePlaybackCache.supports("file:///storage/a.mp4", null))
        assertFalse(PhonePlaybackCache.supports("https://test/a.m3u8", null))
        assertFalse(PhonePlaybackCache.supports("https://test/stream", "application/dash+xml"))
    }

    @Test fun `repeated video reads use storage while subtitle requests bypass it`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val cache = PhonePlaybackCache.acquire(context, 1024 * 1024)
        val data = ByteArray(1000) { (it % 251).toByte() }
        var requests = 0
        val upstream = androidx.media3.datasource.DataSource.Factory {
            val delegate = androidx.media3.datasource.ByteArrayDataSource(data)
            object : androidx.media3.datasource.DataSource by delegate {
                override fun open(spec: androidx.media3.datasource.DataSpec): Long {
                    requests++
                    return delegate.open(spec)
                }
            }
        }
        val factory = PhonePlaybackCache.factory(upstream, "https://test/reuse.mp4", emptyMap(), cache, 0)
        fun read(url: String) {
            val source = factory.createDataSource()
            try {
                source.open(androidx.media3.datasource.DataSpec(android.net.Uri.parse(url)))
                val result = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(100)
                while (true) {
                    val count = source.read(buffer, 0, buffer.size)
                    if (count == androidx.media3.common.C.RESULT_END_OF_INPUT) break
                    result.write(buffer, 0, count)
                }
                assertArrayEquals(data, result.toByteArray())
            } finally { source.close() }
        }
        try {
            read("https://test/reuse.mp4")
            assertEquals(1, requests)
            read("https://test/reuse.mp4")
            assertEquals(1, requests)
            read("https://test/sub.vtt")
            read("https://test/sub.vtt")
            assertEquals(3, requests)
        } finally {
            PhonePlaybackCache.release()
            PhonePlaybackCache.clear()
        }
    }

    @Test fun `disk cache is reusable resizable and cannot clear while in use`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val first = PhonePlaybackCache.acquire(context, 1024 * 1024)
        try {
            assertFalse(PhonePlaybackCache.clear())
            val hole = first.startReadWrite("test", 0, 3)
            try {
                val file = first.startFile("test", 0, 3)
                file.writeBytes(byteArrayOf(1, 2, 3))
                first.commitFile(file, 3)
            } finally { first.releaseHoleSpan(hole) }
            assertEquals(3, PhonePlaybackCache.sizeBytes())
        } finally { PhonePlaybackCache.release() }
        val reopened = PhonePlaybackCache.acquire(context, 2 * 1024 * 1024)
        assertEquals(3, reopened.cacheSpace)
        PhonePlaybackCache.release()
        assertTrue(PhonePlaybackCache.clear())
        assertEquals(0, PhonePlaybackCache.sizeBytes())
    }
}
