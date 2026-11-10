package com.spyou.watch_app

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class TorrentStopCompletionTest {
    @Test fun `stop acknowledges only after torrent cleanup finishes`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val messenger = object : BinaryMessenger {
            override fun send(channel: String, message: ByteBuffer?) {}
            override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
            override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        }
        val engine = TorrentEngine(context, messenger)
        val marker = File(context.cacheDir, "torrents/pending.tmp")
        marker.parentFile!!.mkdirs()
        marker.writeText("pending")
        val complete = AtomicBoolean(false)
        val result = object : MethodChannel.Result {
            override fun success(value: Any?) {
                assertFalse(marker.exists())
                assertSame(Looper.getMainLooper(), Looper.myLooper())
                complete.set(true)
            }
            override fun error(code: String, message: String?, details: Any?) { fail(code) }
            override fun notImplemented() { fail("stop not implemented") }
        }
        TorrentEngine::class.java.getDeclaredMethod("stopStream", String::class.java, MethodChannel.Result::class.java)
            .apply { isAccessible = true }.invoke(engine, "", result)
        val deadline = System.currentTimeMillis() + 5000
        while (!complete.get() && System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(1)
        }
        assertTrue(complete.get())
    }
}
