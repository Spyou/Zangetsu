package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SubtitleOutlineTest {
    private fun assertLook(border: Float, blur: Float, shadow: Float, actual: SubtitleOutline.Look) {
        assertEquals(border, actual.border, 0.001f)
        assertEquals(blur, actual.blur, 0.001f)
        assertEquals(shadow, actual.shadow, 0.001f)
    }

    @Test
    fun `presets match the MPV player's numbers`() {
        assertLook(0f, 0f, 0f, SubtitleOutline.look("none", 3f))
        assertLook(3f, 0f, 0f, SubtitleOutline.look("outline", 3f))
        assertLook(5.4f, 0f, 0f, SubtitleOutline.look("bold", 3f))
        assertLook(1.8f, 0f, 3f, SubtitleOutline.look("shadow", 3f))
        assertLook(2.4f, 12f, 0f, SubtitleOutline.look("glow", 3f))
        assertLook(1.5f, 6f, 0f, SubtitleOutline.look("soft", 3f))
    }

    @Test
    fun `width is clamped and thicker means a thicker outline`() {
        assertEquals(8f, SubtitleOutline.look("outline", 99f).border, 0f)
        assertEquals(0f, SubtitleOutline.look("outline", -1f).border, 0f)
        assertTrue(SubtitleOutline.look("outline", 4f).border > SubtitleOutline.look("outline", 1f).border)
    }

    @Test
    fun `an unknown preset falls back to the soft halo`() {
        assertEquals(SubtitleOutline.look("soft", 2f), SubtitleOutline.look("nonsense", 2f))
    }
}
