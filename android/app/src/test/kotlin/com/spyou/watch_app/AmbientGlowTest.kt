package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Test

class AmbientGlowTest {
    @Test
    fun `white frame glows white with a darker lower half`() {
        val (top, bottom) = ambientGlowColors(IntArray(16) { 0xFFFFFFFF.toInt() })
        assertEquals(0xFFFFFFFF.toInt(), top)
        assertEquals(140, (bottom shr 16) and 0xFF)
    }

    @Test
    fun `black frame stays a near-black lift`() {
        val (top, bottom) = ambientGlowColors(IntArray(16) { 0xFF000000.toInt() })
        assertEquals(22, top and 0xFF)
        assertEquals(12, bottom and 0xFF)
    }

    @Test
    fun `average of black and white lands in the middle`() {
        val pixels = IntArray(8) { 0xFF000000.toInt() } + IntArray(8) { 0xFFFFFFFF.toInt() }
        val (top, _) = ambientGlowColors(pixels)
        assertEquals(149, top and 0xFF)
    }

    @Test
    fun `4 by 3 video in a 16 by 9 view crops the side bars`() {
        val (x, y, w, h) = videoSampleRect(32, 18, 4, 3)
        assertEquals(4, x)
        assertEquals(0, y)
        assertEquals(24, w)
        assertEquals(18, h)
    }

    @Test
    fun `wide video crops top and bottom bars`() {
        val (x, y, w, h) = videoSampleRect(32, 18, 21, 9)
        assertEquals(0, x)
        assertEquals(2, y)
        assertEquals(32, w)
        assertEquals(14, h)
    }
}
