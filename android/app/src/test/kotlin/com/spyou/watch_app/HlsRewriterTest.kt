package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Test

/** Unit tests for [HlsRewriter.rewrite] (formerly AniyomiVideoProxy.rewritePlaylistUrls). */
class HlsRewriterTest {

    private val BASE_URL = "https://cdn.example.com/show/master.m3u8"

    // Recorder resolver: captures each absolute URI it is handed, returns a marker.
    private fun makeRecorder(calls: MutableList<String>): (String) -> String = { uri ->
        calls.add(uri)
        "LOCAL(${calls.size})"
    }

    @Test
    fun relativeSegment_isResolvedToAbsolute_andProxied() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTINF:6.0,\nseg001.ts\n"
        val result = HlsRewriter.rewrite(playlist, BASE_URL, makeRecorder(calls))
        assertEquals(1, calls.size)
        assertEquals("https://cdn.example.com/show/seg001.ts", calls[0])
        assertEquals("#EXTINF:6.0,\nLOCAL(1)", result.trim())
    }

    @Test
    fun absoluteSegment_isPassedThroughToResolver_unchanged() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTINF:6.0,\nhttps://other.cdn.com/seg002.ts\n"
        HlsRewriter.rewrite(playlist, BASE_URL, makeRecorder(calls))
        assertEquals(1, calls.size)
        assertEquals("https://other.cdn.com/seg002.ts", calls[0])
    }

    @Test
    fun extXKeyUri_isRewrittenInPlace_otherAttributesUnchanged() {
        val calls = mutableListOf<String>()
        val playlist =
            "#EXT-X-KEY:METHOD=AES-128,URI=\"enc.key\",IV=0x123\n#EXTINF:6.0,\nseg.ts\n"
        val result = HlsRewriter.rewrite(playlist, BASE_URL, makeRecorder(calls))
        assertEquals(2, calls.size)
        assertEquals("https://cdn.example.com/show/enc.key", calls[0])
        assertEquals("https://cdn.example.com/show/seg.ts", calls[1])
        assert(result.contains("METHOD=AES-128"))
        assert(result.contains("IV=0x123"))
        assert(result.contains("URI=\"LOCAL(1)\""))
    }

    @Test
    fun extXMapUri_isRewritten() {
        val calls = mutableListOf<String>()
        val playlist = "#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6.0,\nseg.m4s\n"
        val result = HlsRewriter.rewrite(playlist, BASE_URL, makeRecorder(calls))
        assertEquals(2, calls.size)
        assertEquals("https://cdn.example.com/show/init.mp4", calls[0])
        assert(result.contains("URI=\"LOCAL(1)\""))
    }

    @Test
    fun hashLines_areNeverPassedToResolver() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n"
        HlsRewriter.rewrite(playlist, BASE_URL, makeRecorder(calls))
        assertEquals("no calls expected for #-only playlist", 0, calls.size)
    }

    @Test
    fun blankLines_arePreservedAsIs() {
        val calls = mutableListOf<String>()
        val playlist = "#EXTINF:6.0,\n\nseg.ts\n"
        val result = HlsRewriter.rewrite(playlist, BASE_URL, makeRecorder(calls))
        assertEquals(1, calls.size)
        assert(result.contains("\n\n"))
    }

    @Test
    fun rootRelativeUri_usesSchemeAndHost() {
        val calls = mutableListOf<String>()
        HlsRewriter.rewrite("#EXTINF:6.0,\n/abs/seg.ts\n", BASE_URL, makeRecorder(calls))
        assertEquals("https://cdn.example.com/abs/seg.ts", calls[0])
    }

    @Test
    fun protocolRelativeUri_getsHttpsScheme() {
        val calls = mutableListOf<String>()
        HlsRewriter.rewrite("#EXTINF:6.0,\n//h.cdn.com/seg.ts\n", BASE_URL, makeRecorder(calls))
        assertEquals("https://h.cdn.com/seg.ts", calls[0])
    }
}
