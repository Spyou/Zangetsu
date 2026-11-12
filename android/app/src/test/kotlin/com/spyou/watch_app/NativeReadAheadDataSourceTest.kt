package com.spyou.watch_app

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class NativeReadAheadDataSourceTest {
    private class Source(val content: ByteArray, val failAfter: Int = Int.MAX_VALUE) : DataSource {
        var offset = 0
        override fun open(spec: DataSpec): Long { offset = spec.position.toInt(); return (content.size - offset).toLong() }
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (this.offset >= failAfter) throw IOException("test failure")
            if (this.offset == content.size) return C.RESULT_END_OF_INPUT
            val count = minOf(length, content.size - this.offset, failAfter - this.offset)
            content.copyInto(buffer, offset, this.offset, this.offset + count)
            this.offset += count
            return count
        }
        override fun close() {}
        override fun getUri(): Uri = Uri.parse("https://test/video.mp4")
        override fun addTransferListener(listener: TransferListener) {}
    }

    @Test fun `bounded ring preserves all bytes through wraparound and reopening`() {
        val original = ByteArray(10003) { (it % 251).toByte() }
        val freed = CountDownLatch(2)
        val source = NativeReadAheadDataSource(DataSource.Factory { Source(original) }, 31,
            allocate = { ByteBuffer.allocateDirect(it) }, release = { freed.countDown() })
        for (start in listOf(0, 777)) {
            source.open(DataSpec.Builder().setUri("https://test/video.mp4").setPosition(start.toLong()).build())
            val received = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(23)
            assertEquals(0, source.read(chunk, 0, 0))
            while (true) {
                val count = source.read(chunk, 0, chunk.size)
                if (count == C.RESULT_END_OF_INPUT) break
                received.write(chunk, 0, count)
            }
            assertArrayEquals(original.copyOfRange(start, original.size), received.toByteArray())
            source.close()
        }
        assertTrue(freed.await(2, TimeUnit.SECONDS))
    }

    @Test fun `upstream failure is delivered after queued bytes`() {
        val source = NativeReadAheadDataSource(DataSource.Factory { Source(ByteArray(100), 17) }, 31,
            allocate = { ByteBuffer.allocateDirect(it) }, release = {})
        source.open(DataSpec(Uri.parse("https://test/video.mp4")))
        var received = 0
        try {
            val chunk = ByteArray(8)
            while (true) received += source.read(chunk, 0, chunk.size)
        } catch (error: IOException) {
            assertEquals("test failure", error.message)
            assertEquals(17, received)
        } finally { source.close() }
    }

    @Test fun `close wakes a full producer and releases its mapping`() {
        val freed = CountDownLatch(1)
        val source = NativeReadAheadDataSource(DataSource.Factory { Source(ByteArray(100000)) }, 16,
            allocate = { ByteBuffer.allocateDirect(it) }, release = { freed.countDown() })
        source.open(DataSpec(Uri.parse("https://test/video.mp4")))
        source.close()
        source.close()
        assertTrue(freed.await(2, TimeUnit.SECONDS))
    }

    @Test fun `allocation failure keeps ordinary streaming working`() {
        val data = byteArrayOf(1, 2, 3)
        val source = NativeReadAheadDataSource(DataSource.Factory { Source(data) }, 16,
            allocate = { throw OutOfMemoryError("test") }, release = {})
        source.open(DataSpec(Uri.parse("https://test/video.mp4")))
        val output = ByteArray(3)
        assertEquals(3, source.read(output, 0, 3))
        assertArrayEquals(data, output)
        source.close()
    }
}
