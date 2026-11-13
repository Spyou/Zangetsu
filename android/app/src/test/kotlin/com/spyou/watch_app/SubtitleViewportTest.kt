package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.view.View
import androidx.media3.common.text.Cue
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import androidx.test.core.app.ApplicationProvider
import io.flutter.plugin.common.BinaryMessenger
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class SubtitleViewportTest {
    private fun playerView() = PlayerView(ApplicationProvider.getApplicationContext())

    private fun layout(view: View, width: Int, height: Int) {
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, width, height)
    }

    private fun checkResize(width: Int, height: Int, videoRatio: Float) {
        val view = playerView()
        view.keepSubtitlesInViewport()
        val subtitles = view.subtitleView!!
        val content = view.findViewById<AspectRatioFrameLayout>(androidx.media3.ui.R.id.exo_content_frame)
        content.setAspectRatio(videoRatio)
        val videoSizes = mutableSetOf<Pair<Int, Int>>()
        for (mode in listOf(AspectRatioFrameLayout.RESIZE_MODE_FIT,
            AspectRatioFrameLayout.RESIZE_MODE_FILL, AspectRatioFrameLayout.RESIZE_MODE_ZOOM)) {
            view.resizeMode = mode
            layout(view, width, height)
            videoSizes.add(content.width to content.height)
            assertSame("subtitles belong to the viewport, not the resized video", view, subtitles.parent)
            assertEquals(width, subtitles.width)
            assertEquals(height, subtitles.height)
            assertEquals(0, subtitles.left)
            assertEquals(0, subtitles.top)
            assertEquals(1f, subtitles.scaleX, 0.0001f)
            assertEquals(1f, subtitles.scaleY, 0.0001f)
        }
        assertTrue("the video must still resize", videoSizes.size > 1)
    }

    @Test fun landscapeVideoResizesWithoutMovingSubtitles() = checkResize(1280, 720, 4f / 3f)

    @Test fun portraitVideoResizesWithoutMovingSubtitles() = checkResize(720, 1280, 16f / 9f)

    @Test fun phonePlayerAttachesSubtitlesToItsViewport() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        try {
            val view = controller.get().findViewById<PlayerView>(R.id.player_view)
            assertSame(view, view.subtitleView!!.parent)
        } finally {
            controller.pause().stop().destroy()
        }
    }

    @Test fun tvPlayerAttachesSubtitlesToItsViewport() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, TvPlayerActivity::class.java)
            .putExtra(TvPlayerActivity.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(TvPlayerActivity::class.java, intent)
            .create().start().resume()
        try {
            val view = controller.get().findViewById<PlayerView>(R.id.player_view)
            assertSame(view, view.subtitleView!!.parent)
        } finally {
            controller.pause().stop().destroy()
        }
    }

    @Test fun embeddedPlayerAttachesSubtitlesToItsViewport() {
        val messenger = object : BinaryMessenger {
            override fun send(channel: String, message: ByteBuffer?) {}
            override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
            override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        }
        val host = ExoPlayerView(ApplicationProvider.getApplicationContext(), 1, messenger)
        try {
            val view = host.getView() as PlayerView
            assertSame(view, view.subtitleView!!.parent)
        } finally {
            host.dispose()
        }
    }

    @Test fun attachingTwiceKeepsCueDataAndOverlayOrder() {
        val view = playerView()
        val subtitles = view.subtitleView!!
        val cues = listOf(Cue.Builder().setText("Same subtitle").setLine(0.9f, Cue.LINE_TYPE_FRACTION).build())
        subtitles.setCues(cues)
        val count = view.childCount
        view.keepSubtitlesInViewport()
        view.keepSubtitlesInViewport()
        assertSame(subtitles, view.subtitleView)
        assertSame(view, subtitles.parent)
        assertEquals(count + 1, view.childCount)
        val content = view.findViewById<View>(androidx.media3.ui.R.id.exo_content_frame)
        val overlay = view.findViewById<View>(androidx.media3.ui.R.id.exo_overlay)
        assertTrue(view.indexOfChild(content) < view.indexOfChild(subtitles))
        assertTrue(view.indexOfChild(subtitles) < view.indexOfChild(overlay))
        val field = SubtitleView::class.java.getDeclaredField("cues").apply { isAccessible = true }
        assertEquals(cues, field.get(subtitles))
    }
}
