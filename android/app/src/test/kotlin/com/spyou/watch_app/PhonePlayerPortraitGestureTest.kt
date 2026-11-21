package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.TextView
import androidx.media3.common.PlaybackParameters
import androidx.media3.ui.PlayerView
import androidx.test.core.app.ApplicationProvider
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
class PhonePlayerPortraitGestureTest {
    @Test fun `portrait video swipe up opens landscape`() = withPlayer { activity, stage ->
        swipe(stage, 160f, 140f, 35f)
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, activity.requestedOrientation)
    }

    @Test fun `short portrait pull moves the video and snaps back`() = withPlayer { activity, stage ->
        val down = SystemClock.uptimeMillis()
        touch(stage, down, MotionEvent.ACTION_DOWN, 160f, 135f)
        touch(stage, down, MotionEvent.ACTION_MOVE, 160f, 90f)
        org.junit.Assert.assertTrue(stage.translationY < 0f)
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, activity.requestedOrientation)
        touch(stage, down, MotionEvent.ACTION_UP, 160f, 90f)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(250))
        assertEquals(0f, stage.translationY, 0.001f)
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, activity.requestedOrientation)
    }

    @Test
    @Config(qualifiers = "land")
    fun `landscape center swipe down returns to portrait`() =
        withPlayer(orientation = "landscape") { activity, stage ->
            swipe(stage, 160f, 35f, 140f)
            assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, activity.requestedOrientation)
        }

    @Test fun `holding portrait video shows the speed badge until release or cancel`() =
        withPlayer(block = ::assertHoldSpeed)

    @Test
    @Config(qualifiers = "land")
    fun `holding fullscreen video shows the speed badge until release or cancel`() =
        withPlayer(orientation = "landscape", block = ::assertHoldSpeed)

    private fun assertHoldSpeed(activity: PhonePlayerActivity, stage: View) {
        val player = requireNotNull(activity.findViewById<PlayerView>(R.id.player_view).player)
        val original = PlaybackParameters(1.25f, 0.9f)
        player.playbackParameters = original
        player.playWhenReady = true

        for (end in listOf(MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL)) {
            val down = SystemClock.uptimeMillis()
            touch(stage, down, MotionEvent.ACTION_DOWN, 160f, 90f)
            shadowOf(Looper.getMainLooper()).idleFor(
                Duration.ofMillis(ViewConfiguration.getLongPressTimeout().toLong() + 100),
            )
            assertEquals(PlaybackParameters(2f, original.pitch), player.playbackParameters)
            val badge = speedBadge(stage)
            assertEquals(View.VISIBLE, badge.visibility)
            touch(stage, down, end, 160f, 90f)
            assertEquals(original, player.playbackParameters)
            assertEquals(View.GONE, badge.visibility)
        }
    }

    private fun speedBadge(stage: View): TextView {
        val group = stage as ViewGroup
        return (0 until group.childCount).asSequence()
            .map { group.getChildAt(it) }
            .filterIsInstance<TextView>()
            .single { it.text == "2×" }
    }

    @Test fun `swiping the portrait video does not adjust brightness`() = withPlayer { activity, stage ->
        assertEquals(0.4f, brightnessAfterSwipe(activity, stage), 0.001f)
    }

    @Test
    @Config(qualifiers = "land")
    fun `swiping fullscreen video still adjusts brightness`() =
        withPlayer(orientation = "landscape") { activity, stage ->
            val player = requireNotNull(activity.findViewById<PlayerView>(R.id.player_view).player)
            val original = player.playbackParameters
            player.playWhenReady = true
            assertEquals(1f, brightnessAfterSwipe(activity, stage), 0.001f)
            assertEquals(original, player.playbackParameters)
        }

    private fun brightnessAfterSwipe(activity: PhonePlayerActivity, stage: View): Float {
        activity.window.attributes = activity.window.attributes.apply { screenBrightness = 0.4f }
        val down = SystemClock.uptimeMillis()
        touch(stage, down, MotionEvent.ACTION_DOWN, 60f, 155f)
        touch(stage, down, MotionEvent.ACTION_MOVE, 60f, 105f)
        touch(stage, down, MotionEvent.ACTION_MOVE, 60f, 55f)
        shadowOf(Looper.getMainLooper()).idleFor(
            Duration.ofMillis(ViewConfiguration.getLongPressTimeout().toLong() + 100),
        )
        assertEquals(View.GONE, speedBadge(stage).visibility)
        touch(stage, down, MotionEvent.ACTION_UP, 60f, 55f)
        return activity.window.attributes.screenBrightness
    }

    private fun swipe(stage: View, x: Float, start: Float, end: Float) {
        val down = SystemClock.uptimeMillis()
        touch(stage, down, MotionEvent.ACTION_DOWN, x, start)
        touch(stage, down, MotionEvent.ACTION_MOVE, x, (start + end) / 2)
        touch(stage, down, MotionEvent.ACTION_MOVE, x, end)
        touch(stage, down, MotionEvent.ACTION_UP, x, end)
    }

    private fun withPlayer(
        orientation: String = "portrait",
        block: (PhonePlayerActivity, View) -> Unit,
    ) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_ORIENTATION, orientation)
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        try {
            val activity = controller.get()
            val stage = activity.findViewById<View>(R.id.player_root)
            activity.findViewById<View>(R.id.controls).visibility = View.GONE
            stage.layout(0, 0, 320, 180)
            block(activity, stage)
        } finally {
            controller.pause().stop().destroy()
        }
    }

    private fun touch(stage: View, down: Long, action: Int, x: Float, y: Float) {
        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0)
        try {
            stage.dispatchTouchEvent(event)
        } finally {
            event.recycle()
        }
    }
}
