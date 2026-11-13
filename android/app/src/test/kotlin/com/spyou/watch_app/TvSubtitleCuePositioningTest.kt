package com.spyou.watch_app

import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.media3.common.text.Cue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TvSubtitleCuePositioningTest {
    private val width = 1280
    private val height = 720
    private val fraction = 0.0533f
    private val paint = TextPaint().apply {
        textSize = height * fraction
        typeface = Typeface.DEFAULT
    }

    private fun cue(text: String) = Cue.Builder().setText(text).build()

    private fun position(cues: List<Cue>, percent: Int = 95) =
        TvSubtitleCuePositioning.position(cues, percent, fraction, width, height, Typeface.DEFAULT)

    @Suppress("DEPRECATION")
    private fun textHeight(cue: Cue): Int {
        val padding = (paint.textSize * 0.125f + 0.5f).toInt()
        val available = ((width - 2 * padding) *
            if (cue.size == Cue.DIMEN_UNSET) 1f else cue.size).toInt()
        return StaticLayout(cue.text.toString(), paint, available,
            Layout.Alignment.ALIGN_CENTER, 1f, 0f, true).height
    }

    private fun assertSeparated(cues: List<Cue>) {
        val positioned = position(cues)
        for (i in 1 until positioned.size) {
            val lowerTop = positioned[i - 1].line * height - textHeight(cues[i - 1])
            val upperBottom = positioned[i].line * height
            assertTrue("subtitle $i overlaps the block below it", upperBottom <= lowerTop)
        }
    }

    @Test fun multilineDisclaimerDoesNotOverlapDialogue() {
        assertSeparated(listOf(cue("This story is a work of fiction.\nNames have no real-life counterparts."),
            cue("How did this happen?")))
    }

    @Test fun wrappedTextDoesNotOverlapDialogue() {
        val long = cue("This story is a work of fiction. People, organizations, locations, laws, " +
            "names and events have no real-life counterparts or connections.")
        assertTrue(textHeight(long) > paint.textSize * 2)
        assertSeparated(listOf(long, cue("How did this happen?")))
    }

    @Test fun narrowCuesUseTheirOwnWrappingWidth() {
        val narrow = cue("A long description that wraps into several lines in a narrow subtitle block.")
            .buildUpon().setSize(0.35f).build()
        assertSeparated(listOf(narrow, cue("A second speaker")))
    }

    @Test fun highPositionKeepsTheWholeGroupVisible() {
        val cues = listOf(cue("One\nTwo\nThree"), cue("A second speaker"))
        val result = position(cues, 0)
        for (i in cues.indices) {
            assertTrue(result[i].line * height - textHeight(cues[i]) >= -1f)
            assertTrue(result[i].line <= 1f)
        }
    }

    @Test fun emptyCuesAreSafeBeforeLayout() {
        assertTrue(position(emptyList()).isEmpty())
        val cues = listOf(cue("One"), cue("Two"))
        val fallback = TvSubtitleCuePositioning.position(cues, 95, fraction, 0, 0, Typeface.DEFAULT)
        assertEquals(SubtitleCuePositioning.position(cues, 95, fraction).map { it.line },
            fallback.map { it.line })
    }

    @Test fun singleCueKeepsTheSelectedPosition() {
        assertEquals(0.70f, position(listOf(cue("Only one")), 70).single().line, 0.0001f)
    }
}
