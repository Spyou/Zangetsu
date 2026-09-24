package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhonePlayerIntentTest {
    @Test
    fun `headers round-trip through the flat array`() {
        val headers = mapOf("Referer" to "https://example.test/", "User-Agent" to "Z/1.0")
        val flat = PhonePlayerIntent.headersToArray(headers)
        assertEquals(4, flat.size)
        assertEquals(headers, PhonePlayerIntent.headersFromArray(flat))
    }

    @Test
    fun `null and empty headers give an empty array and an empty map`() {
        assertEquals(0, PhonePlayerIntent.headersToArray(null).size)
        assertEquals(0, PhonePlayerIntent.headersToArray(emptyMap()).size)
        assertTrue(PhonePlayerIntent.headersFromArray(null).isEmpty())
        assertTrue(PhonePlayerIntent.headersFromArray(emptyArray()).isEmpty())
    }

    @Test
    fun `an odd-length array drops the dangling key instead of throwing`() {
        // A truncated extra must not crash playback; the header is simply lost.
        val parsed = PhonePlayerIntent.headersFromArray(arrayOf("Referer", "https://a/", "Origin"))
        assertEquals(mapOf("Referer" to "https://a/"), parsed)
    }

    @Test
    fun `phone keys do not collide with the TV player's`() {
        // Both Activities read their own extras off their own Intent, so equal
        // string values are harmless — this test exists to make a future
        // "just share the constants" refactor fail loudly instead of quietly
        // coupling the two players.
        assertEquals("url", PhonePlayerIntent.EXTRA_URL)
        assertEquals("positionMs", PhonePlayerIntent.RESULT_POSITION)
        assertEquals("autoResume", PhonePlayerIntent.EXTRA_AUTO_RESUME)
        assertEquals("keepScreenOn", PhonePlayerIntent.EXTRA_KEEP_SCREEN_ON)
        assertEquals("autoplayNext", PhonePlayerIntent.EXTRA_AUTOPLAY_NEXT)
        assertEquals("seekSeconds", PhonePlayerIntent.EXTRA_SEEK_SECONDS)
        assertEquals("subFormats", PhonePlayerIntent.EXTRA_SUB_FORMATS)
        assertEquals("subDefaults", PhonePlayerIntent.EXTRA_SUB_DEFAULTS)
        assertEquals("subtitleEdgeColor", PhonePlayerIntent.EXTRA_SUB_EDGE_COLOR)
        assertEquals("subtitlePreference", PhonePlayerIntent.EXTRA_SUB_PREFERENCE)
    }
}
