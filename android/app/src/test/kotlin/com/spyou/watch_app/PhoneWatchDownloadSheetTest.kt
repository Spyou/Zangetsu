package com.spyou.watch_app

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
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
class PhoneWatchDownloadSheetTest {
    private class Messenger : BinaryMessenger {
        val calls = mutableListOf<MethodCall>()
        var reply: BinaryMessenger.BinaryReply? = null
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            val buffer = message!!.duplicate().apply { flip() }
            calls.add(StandardMethodCodec.INSTANCE.decodeMethodCall(buffer))
            reply = callback
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        fun respond(value: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value).apply { flip() }
            val callback = reply
            reply = null
            callback!!.reply(buffer)
        }
    }
    private fun text(view: View, value: String): TextView? {
        if (view is TextView && view.text.toString() == value) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) text(view.getChildAt(i), value)?.let { return it }
        return null
    }

    @Test fun `download sheet selects once and only uses download methods`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val messenger = Messenger()
        val sheet = PhoneWatchDownloadSheet(activity.get(), MethodChannel(messenger, "test"), 7L, 50, "Episode 51", android.graphics.Color.RED, emptyMap())
        try {
            sheet.show()
            assertEquals("watchDownloadOptions", messenger.calls.single().method)
            messenger.respond(mapOf("token" to 42, "category" to "sub", "categories" to listOf("sub", "dub"), "sources" to listOf(mapOf("label" to "Mirror", "quality" to "1080p"))))
            val row = (text(sheet.window!!.decorView, "Mirror")!!.parent as View).parent as View
            row.performClick()
            row.performClick()
            assertEquals(listOf("watchDownloadOptions", "watchDownloadChoose"), messenger.calls.map { it.method })
            val args = messenger.calls.last().arguments as Map<*, *>
            assertEquals(50, args["index"])
            assertEquals(42, args["token"])
            assertEquals(0, args["source"])
            sheet.dismiss()
            messenger.respond(true)
            assertFalse(sheet.isShowing)
        } finally { sheet.dismiss(); activity.pause().stop().destroy() }
    }
}
