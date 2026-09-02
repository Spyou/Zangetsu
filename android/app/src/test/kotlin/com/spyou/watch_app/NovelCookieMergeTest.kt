package com.spyou.watch_app

import okhttp3.Cookie
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Which copy of a cookie the novel client sends.
 *
 * The Cloudflare rule (local wins) and the login rule (the WebView wins) pull
 * in opposite directions for the same name, so the tiebreak is pinned here —
 * getting it backwards either throws away a clearance or sends a logged-out
 * session cookie forever.
 */
class NovelCookieMergeTest {

    private fun cookie(name: String, value: String) =
        Cookie.Builder().name(name).value(value).domain("novelupdates.com").build()

    private fun valueOf(cookies: List<Cookie>, name: String) =
        cookies.single { it.name == name }.value

    @Test
    fun `a response cookie received after the visit wins`() {
        val merged = mergeCookies(
            own = listOf(cookie("cf_clearance", "fresh")),
            fromWebView = listOf(cookie("cf_clearance", "stale")),
            webViewIsNewer = false,
        )
        assertEquals("fresh", valueOf(merged, "cf_clearance"))
    }

    @Test
    fun `a cookie the user just signed in for wins`() {
        val merged = mergeCookies(
            own = listOf(cookie("PHPSESSID", "guest")),
            fromWebView = listOf(cookie("PHPSESSID", "signed-in")),
            webViewIsNewer = true,
        )
        assertEquals("signed-in", valueOf(merged, "PHPSESSID"))
    }

    @Test
    fun `a name only one side holds is always sent`() {
        for (newer in listOf(false, true)) {
            val merged = mergeCookies(
                own = listOf(cookie("local_only", "1")),
                fromWebView = listOf(cookie("webview_only", "2")),
                webViewIsNewer = newer,
            )
            assertEquals("1", valueOf(merged, "local_only"))
            assertEquals("2", valueOf(merged, "webview_only"))
        }
    }

    @Test
    fun `a shared name is never sent twice`() {
        for (newer in listOf(false, true)) {
            val merged = mergeCookies(
                own = listOf(cookie("session", "a")),
                fromWebView = listOf(cookie("session", "b")),
                webViewIsNewer = newer,
            )
            assertEquals(1, merged.size)
        }
    }
}
