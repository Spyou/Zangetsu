package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.FrameLayout
import android.widget.SeekBar
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
            panel.header.findViewById<View>(R.id.watch_search).performClick()
            val dialog = org.robolectric.shadows.ShadowAlertDialog.getLatestAlertDialog()
            dialog.findViewById<android.widget.EditText>(android.R.id.edit).setText("3")
            dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
            val index = PhonePlayerActivity::class.java.getDeclaredField("currentIndex").apply { isAccessible = true }
            assertEquals("Searching must not play another episode", 0, index.getInt(activity))
        } finally { controller.pause().stop().destroy() }
    }
}
