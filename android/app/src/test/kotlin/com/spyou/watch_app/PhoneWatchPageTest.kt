package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.graphics.drawable.RippleDrawable
import android.view.View
import android.widget.FrameLayout
import android.widget.CheckedTextView
import android.widget.EditText
import android.widget.PopupWindow
import android.widget.SeekBar
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34], qualifiers = "port")
class PhoneWatchPageTest {
    @Suppress("UNCHECKED_CAST")
    @Test fun `download icon opens only its episode and synopsis matches detail typography`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val list = RecyclerView(context)
        val opened = mutableListOf<Int>()
        val downloads = mutableListOf<Int>()
        val page = PhoneWatchPage(list, mapOf("canDownload" to true), Array(100) { "Episode ${it + 1}" },
            android.graphics.Color.RED, { null }, { opened.add(it) })
        page.onEpisodeDownload = { downloads.add(it) }
        try {
            page.update(52)
            val adapter = list.adapter as RecyclerView.Adapter<RecyclerView.ViewHolder>
            val holder = adapter.createViewHolder(list, adapter.getItemViewType(1))
            adapter.bindViewHolder(holder, 1)
            val button = holder.itemView.findViewWithTag<View>("download")
            assertEquals(View.VISIBLE, button.visibility)
            button.performClick()
            assertEquals(listOf(50), downloads)
            assertTrue(opened.isEmpty())
            assertEquals(android.graphics.Typeface.ITALIC, org.robolectric.Shadows.shadowOf(holder.itemView.findViewWithTag<android.widget.TextView>("synopsis").typeface).fontDescription.style)
            page.onEpisodeDownload = null
            adapter.bindViewHolder(holder, 1)
            assertEquals(View.GONE, button.visibility)
        } finally { page.close() }
    }

    @Suppress("UNCHECKED_CAST")
    @Test fun `long lists build one range and taps keep the original index in list and grid`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val list = RecyclerView(context)
        val opened = mutableListOf<Int>()
        val page = PhoneWatchPage(list, emptyMap(), Array(1000) { "Episode ${it + 1}" },
            android.graphics.Color.RED, { null }, { opened.add(it) })
        try {
            page.update(52)
            assertEquals(51, list.adapter!!.itemCount)
            val adapter = list.adapter as RecyclerView.Adapter<RecyclerView.ViewHolder>
            fun tapFirst() {
                val holder = adapter.createViewHolder(list, adapter.getItemViewType(1))
                adapter.bindViewHolder(holder, 1)
                holder.itemView.performClick()
            }
            tapFirst()
            page.header.findViewById<View>(R.id.watch_grid).performClick()
            assertEquals(2, adapter.getItemViewType(1))
            tapFirst()
            assertEquals(listOf(50, 50), opened)
        } finally { page.close() }
    }

    @Suppress("UNCHECKED_CAST")
    @Test fun `long press opens actions without playing and uses highlight instead of scale`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val list = RecyclerView(context)
        val opened = mutableListOf<Int>()
        val menus = mutableListOf<Int>()
        val page = PhoneWatchPage(list, emptyMap(), Array(100) { "Episode ${it + 1}" },
            android.graphics.Color.RED, { null }, { opened.add(it) })
        page.onEpisodeMenu = { menus.add(it) }
        try {
            page.update(52)
            val adapter = list.adapter as RecyclerView.Adapter<RecyclerView.ViewHolder>
            repeat(2) {
                val holder = adapter.createViewHolder(list, adapter.getItemViewType(1))
                adapter.bindViewHolder(holder, 1)
                assertTrue(holder.itemView.performLongClick())
                assertTrue(opened.isEmpty())
                assertTrue(holder.itemView.foreground is android.graphics.drawable.RippleDrawable)
                assertEquals(1f, holder.itemView.scaleX)
                page.header.findViewById<View>(R.id.watch_grid).performClick()
            }
            assertEquals(listOf(50, 50), menus)
            page.setWatched(50, true)
            assertTrue(page.isWatched(50))
            page.setWatched(50, false)
            assertFalse(page.isWatched(50))
        } finally { page.close() }
    }

    @Suppress("UNCHECKED_CAST")
    @Test fun `unavailable rows never start playback and metadata keeps its index`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val list = RecyclerView(context)
        val opened = mutableListOf<Int>()
        val page = PhoneWatchPage(list, mapOf("episodes" to listOf(
            mapOf("index" to 1, "title" to "Second title", "synopsis" to "Episode synopsis", "unavailable" to "Not out yet"))),
            arrayOf("First", "Second"), android.graphics.Color.RED, { null }, { opened.add(it) })
        try {
            page.update(0)
            val adapter = list.adapter as RecyclerView.Adapter<RecyclerView.ViewHolder>
            val holder = adapter.createViewHolder(list, adapter.getItemViewType(2))
            adapter.bindViewHolder(holder, 2)
            holder.itemView.performClick()
            assertTrue(opened.isEmpty())
            assertEquals("Second title", page.row(1)!!.title)
            assertEquals("Episode synopsis", page.row(1)!!.description)
            assertEquals(1, page.row(1)!!.index)
        } finally { page.close() }
    }

    @Test fun `portrait uses a lazy inline episode list and keeps menus below the video`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra(PhonePlayerIntent.EXTRA_URL, "file:///dev/null")
            .putExtra(PhonePlayerIntent.EXTRA_ORIENTATION, "portrait")
            .putExtra(PhonePlayerIntent.EXTRA_EP_COUNT, 3)
            .putExtra(PhonePlayerIntent.EXTRA_EP_LABELS, arrayOf("Episode 1", "Episode 2", "Episode 3"))
        val controller = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).create().start().resume()
        try {
            val activity = controller.get()
            fun dp(n: Int) = (n * activity.resources.displayMetrics.density + 0.5f).toInt()
            val list = activity.findViewById<View>(R.id.watch_info)
            assertTrue("Episodes must be recycled instead of inflated eagerly", list is RecyclerView)
            assertEquals(4, (list as RecyclerView).adapter!!.itemCount)
            assertEquals(View.GONE, activity.findViewById<View>(R.id.quick_actions).visibility)
            val seek = activity.findViewById<SeekBar>(R.id.seek)
            assertEquals(dp(24), seek.layoutParams.height)
            val play = activity.findViewById<View>(R.id.btn_play).parent as View
            assertEquals(dp(56), play.layoutParams.height)
            val back = activity.findViewById<View>(R.id.btn_back)
            assertEquals(dp(32), back.layoutParams.height)
            val bar = activity.findViewById<View>(R.id.bottom_bar) as android.view.ViewGroup
            assertSame(seek, bar.getChildAt(0))
            val params = bar.layoutParams as FrameLayout.LayoutParams
            assertEquals(dp(16), params.marginStart + bar.paddingLeft)
            val panelField = PhonePlayerActivity::class.java.getDeclaredField("watchPanel").apply { isAccessible = true }
            val panel = panelField.get(activity) as PhoneWatchPage
            for (id in listOf(R.id.watch_action_subtitles, R.id.watch_search, R.id.watch_episode_more)) {
                val button = panel.header.findViewById<View>(id)
                val ripple = button.background as RippleDrawable
                assertTrue(ripple.findDrawableByLayerId(android.R.id.mask) is android.graphics.drawable.GradientDrawable)
            }
            panel.header.findViewById<View>(R.id.watch_action_more).performClick()
            val more = org.robolectric.shadows.ShadowDialog.getLatestDialog() as android.app.AlertDialog
            val adapter = more.listView.adapter
            val labels = (0 until adapter.count).map { adapter.getItem(it).toString() }
            for (id in listOf(
                R.string.phone_player_title_tracks, R.string.phone_player_menu_sources,
                R.string.phone_player_menu_episodes, R.string.phone_player_menu_rotate,
            )) {
                assertFalse(activity.getString(id), activity.getString(id) in labels)
            }
            for (id in listOf(
                R.string.phone_player_title_speed, R.string.phone_player_title_quality,
                R.string.phone_player_menu_display, R.string.phone_player_menu_switch_player,
            )) {
                assertTrue(activity.getString(id), activity.getString(id) in labels)
            }
            more.dismiss()
            panel.header.findViewById<View>(R.id.watch_search).performClick()
            val dialog = org.robolectric.shadows.ShadowDialog.getLatestDialog()
            val input = dialog.findViewById<EditText>(android.R.id.edit)
            assertTrue(input.hasFocus())
            val go = dialog.findViewById<TextView>(android.R.id.button1)
            assertEquals("Go", go.text.toString())
            input.setText("3")
            go.performClick()
            val index = PhonePlayerActivity::class.java.getDeclaredField("currentIndex").apply { isAccessible = true }
            assertEquals("Searching must not play another episode", 0, index.getInt(activity))

            val field = PhoneWatchPage::class.java.getDeclaredField("episodeOptions").apply { isAccessible = true }
            fun openOptions(): android.view.ViewGroup {
                panel.header.findViewById<View>(R.id.watch_episode_more).performClick()
                val options = field.get(panel) as PopupWindow
                assertTrue(options.isShowing)
                return options.contentView as android.view.ViewGroup
            }
            val items = openOptions()
            val reverse = items.getChildAt(0) as CheckedTextView
            val autoplay = items.getChildAt(1) as CheckedTextView
            assertEquals("Reverse order", reverse.text)
            assertFalse(reverse.isChecked)
            assertEquals("Auto-play", autoplay.text)
            val wasAutoplay = autoplay.isChecked
            autoplay.performClick()
            val reopened = openOptions()
            assertEquals(!wasAutoplay, (reopened.getChildAt(1) as CheckedTextView).isChecked)
            reopened.getChildAt(0).performClick()
            assertTrue((openOptions().getChildAt(0) as CheckedTextView).isChecked)
            (field.get(panel) as PopupWindow).dismiss()

            panel.header.findViewById<View>(R.id.watch_action_subtitles).performClick()
            val tracks = org.robolectric.shadows.ShadowAlertDialog.getLatestAlertDialog()
            val styleRows = arrayListOf<View>()
            tracks.window!!.decorView.findViewsWithText(styleRows, "Subtitle style", View.FIND_VIEWS_WITH_TEXT)
            assertEquals(1, styleRows.size)
            activity.updateSubtitleStyle(1.5f, 75, -1, 0x80000000.toInt(), 1, 0, null)
            val subtitleScale = PhonePlayerActivity::class.java.getDeclaredField("subtitleScale").apply { isAccessible = true }
            assertEquals(1.5f, subtitleScale.getFloat(activity), 0.001f)
        } finally { controller.pause().stop().destroy() }
    }
}
