package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "land")
class PhonePlayerControlWiringTest {
    @Test fun `saved placement moves the working speed action into the top row`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_CONTROLS,
                """{"top":["speed"],"left":["sources","more"],"right":["episodes","rotate","fit"]}""")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        val top = activity.findViewById<ViewGroup>(R.id.fullscreen_top_actions)
        assertEquals(R.id.quick_speed, top.getChildAt(0).id)
        activity.findViewById<View>(R.id.quick_speed).performClick()
        assertTrue(ShadowDialog.getLatestDialog().isShowing)
        ShadowDialog.getLatestDialog().dismiss()
        assertTrue(activity.findViewById<View>(R.id.quick_more).hasOnClickListeners())
        assertTrue(activity.findViewById<View>(R.id.btn_controls_settings).hasOnClickListeners())
        controller.pause().stop().destroy()
    }

    @Test fun `landscape More only includes actions missing from the saved controls`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_CONTROLS,
                """{"top":["speed"],"left":["sources","more"],"right":["episodes","rotate","fit"]}""")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        try {
            val activity = controller.get()
            activity.findViewById<View>(R.id.quick_more).performClick()
            val dialog = ShadowDialog.getLatestDialog() as android.app.AlertDialog
            val adapter = dialog.listView.adapter
            val labels = (0 until adapter.count).map { adapter.getItem(it).toString() }
            for (id in listOf(
                R.string.phone_player_title_speed, R.string.phone_player_menu_sources,
                R.string.phone_player_menu_episodes, R.string.phone_player_menu_rotate,
                R.string.phone_player_menu_display, R.string.phone_player_arrange_controls,
            )) {
                assertFalse(activity.getString(id), activity.getString(id) in labels)
            }
            for (id in listOf(
                R.string.phone_player_title_tracks, R.string.phone_player_title_quality,
                R.string.phone_player_menu_info, R.string.phone_player_menu_switch_player,
            )) {
                assertTrue(activity.getString(id), activity.getString(id) in labels)
            }
            dialog.dismiss()
        } finally {
            controller.pause().stop().destroy()
        }
    }

    @Test fun `episodes open on the right at the current episode`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_EP_COUNT, 12)
            .putExtra(PhonePlayerIntent.EXTRA_EP_LABELS, Array(12) { "Episode ${it + 1}" })
            .putExtra(PhonePlayerIntent.EXTRA_START_INDEX, 8)
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        try {
            controller.get().findViewById<View>(R.id.quick_episodes).performClick()
            val panel = ShadowDialog.getLatestDialog()
            assertEquals(android.view.Gravity.RIGHT, panel.window!!.attributes.gravity)
            val list = panel.findViewById<android.widget.ListView>(android.R.id.list)
            assertEquals(12, list.adapter.count)
            assertEquals(8, list.checkedItemPosition)
            val search = panel.findViewById<android.widget.EditText>(android.R.id.edit)
            search.setText("9")
            assertEquals(1, list.adapter.count)
            assertEquals(8L, list.adapter.getItemId(0))
            assertEquals(0, list.checkedItemPosition)
            assertTrue(list.performItemClick(list.adapter.getView(0, null, list), 0, 8))
            assertFalse(panel.isShowing)
        } finally {
            controller.pause().stop().destroy()
        }
    }

    @Test fun `lock has a working unlock control and Back unlocks before exiting`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        val activity = controller.get()
        activity.findViewById<View>(R.id.btn_controls_lock).performClick()
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.btn_controls_unlock).visibility)
        assertEquals(View.GONE, activity.findViewById<View>(R.id.controls).visibility)
        activity.onBackPressed()
        assertEquals(View.GONE, activity.findViewById<View>(R.id.btn_controls_unlock).visibility)
        assertFalse(activity.isFinishing)
        activity.findViewById<View>(R.id.btn_controls_lock).performClick()
        activity.findViewById<View>(R.id.btn_controls_unlock).performClick()
        assertEquals(View.GONE, activity.findViewById<View>(R.id.btn_controls_unlock).visibility)
        controller.pause().stop().destroy()
    }
}
