package com.spyou.watch_app

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhonePlayerControlLayoutTest {
    @Test fun `moving a native action preserves other engine controls`() {
        val layout = PhonePlayerControlLayout(
            top = listOf("info"), left = listOf("speed", "enhance", "colour", "more"))
        val moved = layout.move("speed", "right")!!
        assertEquals(listOf("enhance", "colour", "more"), moved.left)
        assertEquals(1, moved.asMap().values.flatten().count { it == "speed" })
        assertEquals("speed", moved.right.last())
    }
    @Test fun `more remains reachable and top has the same five control limit`() {
        val full = PhonePlayerControlLayout(top = listOf("info", "speed", "tracks", "quality", "sources"))
        assertNull(full.move("episodes", "top"))
        assertTrue("more" in full.move("more", "hidden")!!.left)
        assertNull(full.move("speed", "invalid"))
    }
    @Test fun `saved layout removes duplicates and preserves unsupported ids`() {
        val layout = PhonePlayerControlLayout.fromJson("""{"top":["info"],"left":["info","enhance"],"right":["speed"]}""")
        assertEquals(listOf("info"), layout.top)
        assertEquals(listOf("enhance", "more"), layout.left)
        assertEquals(listOf("speed"), layout.right)
    }
    @Test fun `malformed saved layouts keep usable defaults`() {
        assertEquals(PhonePlayerControlLayout(), PhonePlayerControlLayout.fromJson("bad"))
        assertEquals(PhonePlayerControlLayout(), PhonePlayerControlLayout.fromJson("{}"))
    }
}
