package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.core.app.ApplicationProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
class PhonePlayerProgressOwnershipTest {
    private class Messenger : BinaryMessenger {
        val calls = mutableListOf<MethodCall>()
        override fun send(channel: String, message: ByteBuffer?) {
            message ?: return
            val copy = message.duplicate()
            copy.flip()
            calls.add(StandardMethodCodec.INSTANCE.decodeMethodCall(copy))
        }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            send(channel, message) // Keep episode resolution pending.
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    @Test fun `closing during resolution saves the loaded episode not the pending one`() = checkSwitch(false, false)
    @Test fun `closing after failed resolution still saves the loaded episode`() = checkSwitch(true, false)
    @Test fun `a resolved new stream owns subsequent progress`() = checkSwitch(false, true)

    private fun checkSwitch(fail: Boolean, resolve: Boolean) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_START_INDEX, 2)
            .putExtra(PhonePlayerIntent.EXTRA_EP_COUNT, 5)
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        fun field(name: String) = PhonePlayerActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun call(name: String, vararg args: Any?) {
            PhonePlayerActivity::class.java.declaredMethods.single { it.name == name }.apply { isAccessible = true }
                .invoke(activity, *args)
        }
        val messenger = Messenger()
        val channelField = PhonePlayerBridge::class.java.getDeclaredField("channel").apply { isAccessible = true }
        val previousChannel = channelField.get(null)
        try {
            (field("player").get(activity) as ExoPlayer).release()
            val fake = Proxy.newProxyInstance(ExoPlayer::class.java.classLoader, arrayOf(ExoPlayer::class.java)) { _, method, _ ->
                when (method.name) {
                    "getCurrentPosition" -> 42_000L
                    "getDuration" -> 100_000L
                    else -> when (method.returnType) {
                        java.lang.Boolean.TYPE -> false
                        java.lang.Integer.TYPE -> 0
                        java.lang.Long.TYPE -> 0L
                        java.lang.Float.TYPE -> 0f
                        else -> null
                    }
                }
            } as ExoPlayer
            field("player").set(activity, fake)
            field("everPlayed").setBoolean(activity, true)
            field("playbackStarted").setBoolean(activity, true)
            channelField.set(null, MethodChannel(messenger, "test/phone_player"))
            call("loadEpisode", 3)
            assertEquals(2, messenger.calls.first { it.method == "saveProgress" }.argument<Int>("index"))
            assertEquals(3, messenger.calls.first { it.method == "resolveEpisode" }.argument<Int>("index"))
            if (fail) call("failSwitch", "Could not load")
            if (resolve) {
                call("applyResolved", 3, mapOf("url" to "file:///new-episode"), field("mediaGeneration").get(activity))
                field("playbackStarted").setBoolean(activity, true)
                call("sendProgress")
                assertEquals(3, messenger.calls.last { it.method == "saveProgress" }.argument<Int>("index"))
            }
            call("reportClosed")
            val closed = messenger.calls.last { it.method == "playerClosed" }
            assertEquals(if (resolve) 3 else 2, closed.argument<Int>("episodeIndex"))
            assertEquals(42_000L, closed.argument<Long>("positionMs"))
        } finally {
            controller.pause().stop().destroy()
            channelField.set(null, previousChannel)
        }
    }
}
