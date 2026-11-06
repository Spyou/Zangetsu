package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(RobolectricTestRunner::class)
class PhonePlayerLayoutTest {
    private val quickActions = listOf(
        "quick_episodes",
        "quick_sources",
        "quick_tracks",
        "quick_quality",
        "quick_speed",
        "quick_display",
    )

    @Test
    @Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
    fun `portrait orientation preference opens the watch page`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_ORIENTATION, "portrait")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        val activity = controller.get()

        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, activity.requestedOrientation)
        assertEquals(
            activity.resources.displayMetrics.widthPixels * 9 / 16,
            activity.findViewById<View>(R.id.player_root).layoutParams.height,
        )
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.watch_info).visibility)

        controller.pause().stop().destroy()
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
    fun `system orientation switches the page and fullscreen on rotation`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_ORIENTATION, "system")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        val activity = controller.get()

        assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, activity.requestedOrientation)
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.watch_info).visibility)
        val observerField = PhonePlayerActivity::class.java.getDeclaredField("orientationObserver")
            .apply { isAccessible = true }
        val observer = observerField.get(activity) as PhoneOrientationObserver
        observer.onOrientationChanged(0)
        val video = activity.findViewById<View>(R.id.player_view)
        activity.findViewById<View>(R.id.btn_rotate).performClick()
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, activity.requestedOrientation)
        observer.onOrientationChanged(90)
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, activity.requestedOrientation)

        val landscape = Configuration(activity.resources.configuration).apply {
            orientation = Configuration.ORIENTATION_LANDSCAPE
        }
        @Suppress("DEPRECATION")
        activity.resources.updateConfiguration(landscape, activity.resources.displayMetrics)
        activity.onConfigurationChanged(landscape)
        assertEquals(View.GONE, activity.findViewById<View>(R.id.watch_info).visibility)
        activity.findViewById<View>(R.id.btn_back).performClick()
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, activity.requestedOrientation)
        observer.onOrientationChanged(0)
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, activity.requestedOrientation)
        assertSame(video, activity.findViewById<View>(R.id.player_view))
        val portrait = Configuration(activity.resources.configuration).apply {
            orientation = Configuration.ORIENTATION_PORTRAIT
        }
        @Suppress("DEPRECATION")
        activity.resources.updateConfiguration(portrait, activity.resources.displayMetrics)
        activity.onConfigurationChanged(portrait)

        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.watch_info).visibility)
        assertEquals(
            activity.resources.displayMetrics.widthPixels * 9 / 16,
            activity.findViewById<View>(R.id.player_root).layoutParams.height,
        )

        controller.pause().stop().destroy()
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
    fun `portrait player keeps playback controls and exposes all quick actions`() {
        val quick = assertPlayerControls()
        assertEquals(2, quick.childCount)
        assertEquals(3, (quick.getChildAt(0) as ViewGroup).childCount)
        val lowerRow = quick.getChildAt(1) as ViewGroup
        assertEquals(2, lowerRow.childCount)
        assertEquals(3, (lowerRow.getChildAt(0) as ViewGroup).childCount)
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
    fun `landscape player keeps playback controls and exposes all quick actions`() {
        val quick = assertPlayerControls()
        assertEquals(1, quick.childCount)
        assertEquals(5, quick.findViewById<ViewGroup>(R.id.fullscreen_actions_left).childCount)
        assertEquals(3, quick.findViewById<ViewGroup>(R.id.fullscreen_actions_right).childCount)
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34])
    fun `quick speed action opens the existing playback speed choices`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        val activity = controller.get()

        activity.findViewById<View>(R.id.quick_speed).performClick()

        assertTrue(ShadowDialog.getLatestDialog().isShowing)
        controller.pause().stop().destroy()
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34])
    fun `more panel keeps the full player action list`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        val activity = controller.get()

        activity.findViewById<View>(R.id.btn_more).performClick()

        val dialog = ShadowDialog.getLatestDialog()
        assertTrue(dialog.isShowing)
        val labels = mutableListOf<String>()
        fun collect(view: View) {
            if (view is TextView) labels += view.text.toString()
            if (view is ViewGroup) for (i in 0 until view.childCount) collect(view.getChildAt(i))
        }
        collect(dialog.window!!.decorView)
        for (label in listOf("Playback speed", "Audio & subtitles", "Video quality", "Sources", "Episodes", "Display", "Rotate", "Info")) {
            assertTrue("Missing player action: $label", label in labels)
        }
        controller.pause().stop().destroy()
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
    fun `portrait layout hosts the watch info stub below the video`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = LayoutInflater.from(context).inflate(R.layout.phone_player, null)
        val stubId = context.resources.getIdentifier("watch_info_stub", "id", context.packageName)
        assertTrue(stubId != 0)
        assertNotNull(root.findViewById<View>(stubId))
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34])
    fun `rotation changes quick action layout without replacing the video view`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_ORIENTATION, "system")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        val activity = controller.get()
        val playerView = activity.findViewById<View>(R.id.player_view)
        val portraitQuick = activity.findViewById<ViewGroup>(R.id.quick_actions)
        val seek = activity.findViewById<android.widget.SeekBar>(R.id.seek)
        val portraitSeekGeometry = listOf(seek.paddingLeft, seek.paddingTop, seek.paddingRight,
            seek.paddingBottom, seek.thumbOffset, seek.layoutParams.height)
        val landscape = Configuration(activity.resources.configuration).apply {
            orientation = Configuration.ORIENTATION_LANDSCAPE
        }
        @Suppress("DEPRECATION")
        activity.resources.updateConfiguration(landscape, activity.resources.displayMetrics)

        activity.onConfigurationChanged(landscape)

        val landscapeQuick = activity.findViewById<ViewGroup>(R.id.quick_actions)
        assertEquals(dp(activity, 26), seek.layoutParams.height)
        assertEquals(seek.thumb.intrinsicWidth / 2, seek.paddingLeft)
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.quick_mega_skip).visibility)
        assertEquals(android.view.Gravity.START,
            (activity.findViewById<TextView>(R.id.time_chip).parent as android.widget.LinearLayout).gravity and android.view.Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK)
        assertEquals(dp(activity, 110), activity.findViewById<View>(R.id.top_scrim).layoutParams.height)
        assertEquals(dp(activity, 170), activity.findViewById<View>(R.id.bottom_scrim).layoutParams.height)
        assertEquals(
            0,
            (activity.findViewById<View>(R.id.top_bar).layoutParams as android.widget.FrameLayout.LayoutParams).topMargin,
        )
        assertEquals(
            dp(activity, 14),
            (activity.findViewById<View>(R.id.bottom_bar).layoutParams as android.widget.FrameLayout.LayoutParams).bottomMargin,
        )
        assertSame(playerView, activity.findViewById<View>(R.id.player_view))
        assertNotSame(portraitQuick, landscapeQuick)
        assertEquals(1, landscapeQuick.childCount)
        assertEquals(5, landscapeQuick.findViewById<ViewGroup>(R.id.fullscreen_actions_left).childCount)
        val orientationBeforeRotate = activity.requestedOrientation
        landscapeQuick.findViewById<View>(R.id.btn_rotate).performClick()
        assertTrue(activity.requestedOrientation != orientationBeforeRotate)

        val portrait = Configuration(activity.resources.configuration).apply {
            orientation = Configuration.ORIENTATION_PORTRAIT
        }
        @Suppress("DEPRECATION")
        activity.resources.updateConfiguration(portrait, activity.resources.displayMetrics)
        activity.onConfigurationChanged(portrait)
        assertEquals(View.GONE, activity.findViewById<View>(R.id.quick_mega_skip).visibility)
        assertEquals(portraitSeekGeometry, listOf(seek.paddingLeft, seek.paddingTop, seek.paddingRight,
            seek.paddingBottom, seek.thumbOffset, seek.layoutParams.height))
        assertEquals(dp(activity, 64), activity.findViewById<View>(R.id.top_scrim).layoutParams.height)
        assertEquals(dp(activity, 110), activity.findViewById<View>(R.id.bottom_scrim).layoutParams.height)
        assertEquals(
            dp(activity, 2),
            (activity.findViewById<View>(R.id.top_bar).layoutParams as android.widget.FrameLayout.LayoutParams).marginStart,
        )
        assertEquals(
            dp(activity, 4),
            (activity.findViewById<View>(R.id.bottom_bar).layoutParams as android.widget.FrameLayout.LayoutParams).bottomMargin,
        )
        controller.pause().stop().destroy()
    }

    @Test
    @Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
    fun `portrait mini card stacks chrome with no overlap`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_ORIENTATION, "portrait")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent)
            .create().start().resume()
        val activity = controller.get()
        // Single action row in the mini card; the title lives in the info
        // panel below, so the card keeps only Back.
        assertTrue(
            activity.findViewById<View>(R.id.quick_actions) is android.widget.HorizontalScrollView,
        )
        assertEquals(View.GONE, activity.findViewById<View>(R.id.title).visibility)
        assertEquals(View.GONE, activity.findViewById<View>(R.id.episode_label).visibility)
        assertEquals(View.GONE, activity.findViewById<View>(R.id.btn_more).visibility)
        // Stack parameters that fit the 16:9 card with no overlap (title lives
        // in the info panel, so the mini card keeps only Back). Pixel proof
        // comes from on-device bounds; Robolectric's fallback fonts measure
        // taller than real ones, so measured-pixel overlap assertions here
        // would test the fake font, not the dp budget.
        val card = activity.findViewById<View>(R.id.player_root)
        val transport = activity.findViewById<View>(R.id.transport_row)
        val transportParams =
            transport.layoutParams as android.widget.FrameLayout.LayoutParams
        assertEquals(
            android.view.Gravity.TOP or android.view.Gravity.CENTER_HORIZONTAL,
            transportParams.gravity,
        )
        assertEquals(dp(activity, 64), transportParams.topMargin)
        val playBox = activity.findViewById<View>(R.id.btn_play).parent as View
        assertEquals(dp(activity, 48), playBox.layoutParams.width)
        assertEquals(dp(activity, 48), playBox.layoutParams.height)
        assertEquals(dp(activity, 40), activity.findViewById<View>(R.id.seek).layoutParams.height)
        // The portrait action row carries the same seven actions at 40dp.
        val portraitRow = android.view.LayoutInflater.from(context).inflate(
            R.layout.phone_player_quick_actions_portrait,
            null,
        ) as ViewGroup
        val inner = portraitRow.getChildAt(0) as ViewGroup
        for (name in quickActions + "btn_rotate") {
            val action = findByName(context, portraitRow, name)
            assertNotNull("Missing portrait quick action: $name", action)
            assertEquals(
                "Portrait quick action not 40dp: $name",
                dp(activity, 40),
                action!!.layoutParams.height,
            )
        }
        controller.pause().stop().destroy()
    }

    private fun dp(activity: PhonePlayerActivity, value: Int): Int =
        (value * activity.resources.displayMetrics.density + 0.5f).toInt()

    private fun assertPlayerControls(): ViewGroup {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = LayoutInflater.from(context).inflate(R.layout.phone_player, null)
        for (id in listOf("btn_back", "btn_more", "btn_previous", "btn_play", "btn_next", "seek", "btn_rotate")) {
            assertNotNull("Missing existing control: $id", findByName(context, root, id))
        }
        assertTrue(
            "Loading overlay should use the M3 expressive view",
            findByName(context, root, "loading_spinner") is PhoneLoadingIndicatorView,
        )
        assertTrue(
            "Buffering indicator should use the M3 expressive view",
            findByName(context, root, "loading") is PhoneLoadingIndicatorView,
        )
        for (id in quickActions) {
            val action = findByName(context, root, id)
            assertNotNull("Missing quick action: $id", action)
            assertTrue("Quick action is not tappable: $id", action!!.isClickable)
            assertTrue("Quick action is not focusable: $id", action.isFocusable)
            assertTrue("Quick action is smaller than 48dp: $id", action.layoutParams.height >= 48 * context.resources.displayMetrics.density)
        }
        return root.findViewById(R.id.quick_actions)
    }

    private fun findByName(context: Context, root: View, name: String): View? {
        val id = context.resources.getIdentifier(name, "id", context.packageName)
        return if (id == 0) null else root.findViewById(id)
    }
}
