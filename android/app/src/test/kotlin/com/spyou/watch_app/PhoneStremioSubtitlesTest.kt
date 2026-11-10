package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.test.core.app.ApplicationProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlertDialog

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
class PhoneStremioSubtitlesTest {
    private class Messenger : BinaryMessenger {
        var reply: BinaryMessenger.BinaryReply? = null
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) { reply = callback }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        fun respond() {
            reply!!.reply(StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(mapOf(
                "subUrls" to listOf("https://sub.test/download/1"),
                "subLangs" to listOf("eng"),
                "subLabels" to listOf("English · OpenSubtitles"),
                "subFormats" to listOf("srt"),
            )).apply { flip() })
        }
    }

    @Test fun `addon subtitles preserve media and playback position when selected`() = check(false)
    @Test fun `late addon subtitles cannot modify a different episode`() = check(true)

    private fun check(stale: Boolean) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_STREMIO_SUBTITLES, true)
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        fun field(name: String) = PhonePlayerActivity::class.java.getDeclaredField(name).apply { isAccessible = true }
        val messenger = Messenger()
        val channelField = PhonePlayerBridge::class.java.getDeclaredField("channel").apply { isAccessible = true }
        val previous = channelField.get(null)
        val media = MediaItem.Builder().setUri("https://video.test/chosen").build()
        var opened: MediaSource? = null
        var position: Long? = null
        try {
            (field("player").get(activity) as ExoPlayer).release()
            val fake = Proxy.newProxyInstance(ExoPlayer::class.java.classLoader, arrayOf(ExoPlayer::class.java)) { _, method, args ->
                when (method.name) {
                    "getCurrentMediaItem" -> media
                    "getCurrentPosition" -> 42_000L
                    "getTrackSelectionParameters" -> TrackSelectionParameters.DEFAULT_WITHOUT_CONTEXT
                    "setMediaSource" -> { opened = args!![0] as MediaSource; position = args.getOrNull(1) as? Long; null }
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
            channelField.set(null, MethodChannel(messenger, "test/phone_player"))
            PhonePlayerActivity::class.java.getDeclaredMethod("showAddonSubtitles").apply { isAccessible = true }.invoke(activity)
            val loading = ShadowAlertDialog.getLatestAlertDialog()
            if (stale) field("mediaGeneration").setInt(activity, field("mediaGeneration").getInt(activity) + 1)
            messenger.respond()
            assertFalse(loading.isShowing)
            if (stale) {
                assertNull(opened)
            } else {
                val picker = ShadowAlertDialog.getLatestAlertDialog()
                picker.listView.performItemClick(null, 0, 0L)
                assertEquals(42_000L, position)
                assertEquals(media.localConfiguration!!.uri, opened!!.mediaItem.localConfiguration!!.uri)
                val track = opened!!.mediaItem.localConfiguration!!.subtitleConfigurations.single()
                assertEquals(MimeTypes.APPLICATION_SUBRIP, track.mimeType)
                assertEquals("English · OpenSubtitles", track.label)
                assertEquals(track.uri.toString(), field("pendingAddonSubtitleId").get(activity))
                picker.dismiss()
            }
        } finally {
            channelField.set(null, previous)
            controller.pause().stop().destroy()
        }
    }
}
