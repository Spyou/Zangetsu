package com.spyou.watch_app.aniyomi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [AniyomiVideoProxy.rewritePlaylistUrls].
 *
 * All tests are pure JVM — no NanoHTTPD server is started and no network
 * calls are made. The [resolveUri] lambda is replaced with a simple recorder
 * that returns a deterministic fake proxy URL for inspection.
 */
class AniyomiVideoProxyTest {

    private val BASE_URL = "https://cdn.example.com/show/playlist.m3u8"

    /**
     * A [resolveUri] stand-in: records every absolute URI it receives and
     * returns a stable fake proxy URL derived from the URI so callers can
     * assert on the output text.
     */
    private fun makeRecorder(calls: MutableList<String>): (String) -> String = { uri ->
        calls.add(uri)
        "http://127.0.0.1:9999/s/FAKETOKEN_${calls.size - 1}"
    }

    // -------------------------------------------------------------------------
    // Relative segment
    // -------------------------------------------------------------------------

    @Test
    fun relativeSegment_isResolvedToAbsolute_andProxied() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:9.009,\nseg001.ts\n#EXT-X-ENDLIST"

        val result = AniyomiVideoProxy.rewritePlaylistUrls(playlist, BASE_URL, makeRecorder(calls))

        // Resolver receives the ABSOLUTE URL, not the raw "seg001.ts"
        assertEquals(1, calls.size)
        assertEquals("https://cdn.example.com/show/seg001.ts", calls[0])

        // Output line is the proxy URL, not the original relative URI
        assertTrue("output must contain proxy url", result.contains("http://127.0.0.1:9999/s/FAKETOKEN_0"))
        assertFalse("raw segment must not appear in output", result.contains("seg001.ts\n") || result.endsWith("seg001.ts"))
    }

    // -------------------------------------------------------------------------
    // Absolute segment (different CDN)
    // -------------------------------------------------------------------------

    @Test
    fun absoluteSegment_isPassedThroughToResolver_unchanged() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTM3U\n#EXTINF:9.009,\nhttps://other.cdn.com/seg002.ts\n#EXT-X-ENDLIST"

        AniyomiVideoProxy.rewritePlaylistUrls(playlist, BASE_URL, makeRecorder(calls))

        assertEquals(1, calls.size)
        assertEquals("https://other.cdn.com/seg002.ts", calls[0])
    }

    // -------------------------------------------------------------------------
    // #EXT-X-KEY URI attribute (AES-128 encryption key)
    // -------------------------------------------------------------------------

    @Test
    fun extXKeyUri_isRewrittenInPlace_otherAttributesUnchanged() {
        val calls = mutableListOf<String>()
        val playlist = buildString {
            appendLine("#EXTM3U")
            appendLine("#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x000102030405060708090a0b0c0d0e0f")
            appendLine("#EXTINF:9.009,")
            appendLine("seg001.ts")
            append("#EXT-X-ENDLIST")
        }

        val result = AniyomiVideoProxy.rewritePlaylistUrls(playlist, BASE_URL, makeRecorder(calls))

        // Both key.bin and seg001.ts must be proxied
        assertEquals(2, calls.size)
        assertTrue("key.bin must be resolved to absolute", calls.any { it == "https://cdn.example.com/show/key.bin" })
        assertTrue("seg001.ts must be resolved to absolute", calls.any { it == "https://cdn.example.com/show/seg001.ts" })

        // The KEY line must contain the proxied URI in the URI="…" attribute
        val keyLine = result.lines().first { it.startsWith("#EXT-X-KEY:") }
        assertTrue("KEY URI must be a proxy url", keyLine.contains("URI=\"http://127.0.0.1:9999/s/FAKETOKEN_"))
        // Non-URI attributes must survive
        assertTrue("METHOD must survive", keyLine.contains("METHOD=AES-128"))
        assertTrue("IV must survive", keyLine.contains("IV=0x000102030405060708090a0b0c0d0e0f"))
    }

    // -------------------------------------------------------------------------
    // #EXT-X-MAP URI attribute (fragmented MP4 init segment)
    // -------------------------------------------------------------------------

    @Test
    fun extXMapUri_isRewritten() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"/init.mp4\"\n#EXTINF:9.009,\nseg.ts\n#EXT-X-ENDLIST"

        val result = AniyomiVideoProxy.rewritePlaylistUrls(playlist, BASE_URL, makeRecorder(calls))

        // /init.mp4 is root-relative → should become https://cdn.example.com/init.mp4
        assertTrue("MAP URI must be resolved root-relative",
            calls.any { it == "https://cdn.example.com/init.mp4" })

        val mapLine = result.lines().first { it.startsWith("#EXT-X-MAP:") }
        assertTrue("MAP URI must be proxied", mapLine.contains("URI=\"http://127.0.0.1:9999/s/FAKETOKEN_"))
    }

    // -------------------------------------------------------------------------
    // Comment / tag lines must NOT be passed to the resolver
    // -------------------------------------------------------------------------

    @Test
    fun hashLines_areNeverPassedToResolver() {
        val calls = mutableListOf<String>()
        // Playlist with no bare URI lines — only #-prefixed content
        val playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:9.009,\n#EXT-X-ENDLIST"

        AniyomiVideoProxy.rewritePlaylistUrls(playlist, BASE_URL, makeRecorder(calls))

        assertEquals("no calls expected for #-only playlist", 0, calls.size)
    }

    // -------------------------------------------------------------------------
    // Blank lines pass through unchanged
    // -------------------------------------------------------------------------

    @Test
    fun blankLines_arePreservedAsIs() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTM3U\n\n#EXTINF:9.009,\nseg.ts\n"

        val result = AniyomiVideoProxy.rewritePlaylistUrls(playlist, BASE_URL, makeRecorder(calls))

        // One segment call only — not for the blank line
        assertEquals(1, calls.size)
        // Blank line preserved in output
        assertTrue("blank line must survive in output", result.contains("\n\n"))
    }
}
