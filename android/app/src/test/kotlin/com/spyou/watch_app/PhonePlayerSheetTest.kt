package com.spyou.watch_app

import android.app.Activity
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhonePlayerSheetTest {
    private fun texts(view: View): List<TextView> = when (view) {
        is TextView -> listOf(view)
        is ViewGroup -> (0 until view.childCount).flatMap { texts(view.getChildAt(it)) }
        else -> emptyList()
    }

    @Test @Config(qualifiers = "land")
    fun `source sheet keeps selection indexes and long press copying`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            var picked = -1
            var copied = -1
            val dialog = PhonePlayerSheet(controller.get())
                .setTitle("Sources")
                .setSingleChoiceItems(arrayOf("First", "Second", "Third"), 1) { d, index ->
                    picked = index
                    d.dismiss()
                }.show()
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            val list = dialog.listView
            list.setOnItemLongClickListener { _, _, index, _ -> copied = index; true }
            val row = list.adapter.getView(1, null, list)
            assertTrue(row.isSelected)
            assertTrue(list.onItemLongClickListener!!.onItemLongClick(list, row, 1, 1))
            assertEquals(1, copied)
            assertTrue(dialog.isShowing)
            val reused = list.adapter.getView(2, row, list)
            assertSame(row, reused)
            assertFalse(reused.isSelected)
            list.performItemClick(reused, 2, 2)
            assertEquals(2, picked)
            assertFalse(dialog.isShowing)
            assertEquals(Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL, dialog.window!!.attributes.gravity)
            assertTrue(dialog.window!!.attributes.width <= controller.get().resources.displayMetrics.widthPixels)
        } finally { controller.pause().stop().destroy() }
    }

    @Test @Config(qualifiers = "port")
    fun `speed chips keep their original indexes and selected rate`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            var picked = -1
            val dialog = PhonePlayerSheet(controller.get())
                .setChips(arrayOf("0.5x", "0.75x", "1.0x", "1.25x", "1.5x", "2.0x"), 2) { d, index ->
                    picked = index
                    d.dismiss()
                }.setTitle("Speed").show()
            val chips = texts(dialog.window!!.decorView)
            assertTrue(chips.single { it.text == "1.0x" }.isSelected)
            chips.single { it.text == "2.0x" }.performClick()
            assertEquals(5, picked)
            assertFalse(dialog.isShowing)
        } finally { controller.pause().stop().destroy() }
    }

    @Test @Config(qualifiers = "port")
    fun `audio and subtitle sheet lists every row and runs the one tapped`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            var picked = ""
            fun row(label: String, selected: Boolean = false, detail: String? = null) =
                PhonePlayerSheet.SheetRow(label, detail = detail, selected = selected) { picked = label }
            val audio = listOf(row("SUB", true), row("DUB"), row("Auto"), row("Japanese", detail = "Stereo · AAC"))
            val subs = listOf(row("Preferred language: Auto"), row("Off"), row("English", true), row("Arabic"))
            val footer = listOf(row("Subtitle style"))
            for (label in (audio + subs + footer).map { it.label }) {
                val dialog = PhonePlayerSheet(controller.get())
                    .setAudioSubtitleSheet(audio, subs, footer).show()
                val items = texts(dialog.window!!.decorView)
                assertTrue(items.single { it.text == "English" }.isShown)
                assertTrue(items.any { it.text == "Stereo · AAC" })
                // A tap lands on the text and bubbles up to the row that owns the click.
                var tapped: android.view.View = items.single { it.text == label }
                while (!tapped.hasOnClickListeners()) tapped = tapped.parent as android.view.View
                tapped.performClick()
                assertEquals(label, picked)
                assertFalse(dialog.isShowing)
            }
        } finally { controller.pause().stop().destroy() }
    }

    @Test @Config(qualifiers = "port")
    fun `delay control steps in quarter seconds, reports once, and flushes on close`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            val reported = mutableListOf<Int>()
            val dialog = PhonePlayerSheet(controller.get())
                .setDelayControl(0) { reported += it }.setTitle("Subtitle delay").show()
            val root = dialog.window!!.decorView
            fun buttons(): List<android.widget.ImageView> {
                val found = mutableListOf<android.widget.ImageView>()
                fun walk(v: android.view.View) {
                    if (v is android.widget.ImageView && v.contentDescription != null) found += v
                    if (v is android.view.ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
                }
                walk(root)
                return found
            }
            val later = buttons().single { it.contentDescription == "Later" }
            repeat(3) { later.performClick() }
            // Three quick taps are one change, and nothing is sent yet.
            assertTrue(reported.isEmpty())
            assertTrue(texts(root).any { it.text == "+0.75s" })
            // Closing the sheet sends the pending total instead of dropping it.
            dialog.dismiss()
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            assertEquals(listOf(750), reported)
        } finally { controller.pause().stop().destroy() }
    }

    @Test @Config(qualifiers = "land")
    fun `long episode lists stay scrollable within the screen`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            val activity = controller.get()
            val original = android.app.AlertDialog.Builder(activity, R.style.PhonePlayerDialog)
                .setSingleChoiceItems(Array(500) { "Episode ${it + 1}" }, 350) { _, _ -> }.show()
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            val originalFocus = original.listView.selectedItemPosition
            original.dismiss()
            val dialog = PhonePlayerSheet(activity).setTitle("Episodes")
                .setSingleChoiceItems(Array(500) { "Episode ${it + 1}" }, 350) { _, _ -> }.show()
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            assertEquals(500, dialog.listView.count)
            assertEquals(350, dialog.listView.checkedItemPosition)
            assertEquals(originalFocus, dialog.listView.selectedItemPosition)
            assertTrue(dialog.listView.layoutParams.height <= activity.resources.displayMetrics.heightPixels * 0.6f)
            assertTrue(dialog.window!!.decorView.height <= activity.resources.displayMetrics.heightPixels)
            dialog.dismiss()
        } finally { controller.pause().stop().destroy() }
    }
}
