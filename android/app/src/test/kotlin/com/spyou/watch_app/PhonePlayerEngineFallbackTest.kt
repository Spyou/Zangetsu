package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
class PhonePlayerEngineFallbackTest {
    private class Messenger : BinaryMessenger {
        val calls = mutableListOf<MethodCall>()
        var reply: BinaryMessenger.BinaryReply? = null
        var onCall: ((MethodCall) -> Unit)? = null
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(message!!.duplicate().apply { flip() })
            calls.add(call)
            onCall?.invoke(call)
            reply = callback
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        fun respond(value: Any?) {
            val pending = reply!!
            reply = null
            pending.reply(StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value).apply { flip() })
        }
    }

    private fun check(enabled: Boolean, action: (PhonePlayerActivity, Messenger) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java,
            Intent(context, PhonePlayerActivity::class.java)
                .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
                .putExtra(PhonePlayerIntent.EXTRA_SESSION, 7L)
                .putExtra(PhonePlayerIntent.EXTRA_AUTO_ENGINE_FALLBACK, enabled))
            .create().start().resume()
        val field = PhonePlayerBridge::class.java.getDeclaredField("channel").apply { isAccessible = true }
        val previous = field.get(null)
        try {
            val messenger = Messenger()
            field.set(null, MethodChannel(messenger, "test/phone_player"))
            action(controller.get(), messenger)
        } finally {
            controller.pause().stop().destroy()
            field.set(null, previous)
        }
    }

    private fun fail(activity: PhonePlayerActivity) {
        PhonePlayerActivity::class.java.getDeclaredMethod("failover").apply { isAccessible = true }.invoke(activity)
    }

    @Test fun `off uses the existing next-mirror flow directly`() = check(false) { activity, messenger ->
        fail(activity)
        assertEquals("sourcesFor", messenger.calls.single().method)
        assertFalse(activity.isFinishing)
    }

    @Test fun `on asks for the same stream before requesting other mirrors`() = check(true) { activity, messenger ->
        fail(activity)
        val call = messenger.calls.single()
        assertEquals("tryOtherPlayer", call.method)
        assertEquals("file:///dev/null", call.argument<String>("url"))
        assertEquals(7L, call.argument<Number>("sessionId")!!.toLong())
        assertEquals(0, call.argument<Number>("index")!!.toInt())
        fail(activity)
        assertEquals(1, messenger.calls.size)
        messenger.respond(false)
        assertEquals("sourcesFor", messenger.calls.last().method)
        assertFalse(activity.isFinishing)
    }

    @Test fun `accepted handoff closes instead of trying another link`() = check(true) { activity, messenger ->
        fail(activity)
        messenger.respond(true)
        assertTrue(activity.isFinishing)
        assertEquals(listOf("tryOtherPlayer"), messenger.calls.map { it.method })
        fail(activity)
        assertEquals(1, messenger.calls.size)
    }

    @Test fun `a late reply cannot switch a newer episode`() = check(true) { activity, messenger ->
        fail(activity)
        val generation = PhonePlayerActivity::class.java.getDeclaredField("mediaGeneration").apply { isAccessible = true }
        generation.setInt(activity, generation.getInt(activity) + 1)
        messenger.respond(true)
        assertFalse(activity.isFinishing)
        assertEquals(1, messenger.calls.size)
    }

    @Test fun `fallback reports closure only after releasing the native player`() {
        var reported = false
        check(true) { activity, messenger ->
            fail(activity)
            messenger.respond(true)
            val player = PhonePlayerActivity::class.java.getDeclaredField("player").apply { isAccessible = true }
            messenger.onCall = { call ->
                if (call.method == "playerClosed") {
                    reported = true
                    assertNull(player.get(activity))
                    assertEquals(true, call.argument<Boolean>("engineFallback"))
                    assertEquals("file:///dev/null", call.argument<String>("url"))
                }
            }
        }
        assertTrue("The handoff must report that its native session closed", reported)
    }
}
