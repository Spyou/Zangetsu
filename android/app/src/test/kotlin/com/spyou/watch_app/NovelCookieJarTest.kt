package com.spyou.watch_app

import android.webkit.CookieManager
import androidx.test.core.app.ApplicationProvider
import com.spyou.watch_app.mihon.SourceWebViewActivity
import com.spyou.watch_app.mihon.WebViewVisits
import java.time.Duration
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSystemClock

/**
 * The wiring around [mergeCookies], which is where the interesting half lives:
 * the merge itself is pinned by NovelCookieMergeTest, but WHICH copy is called
 * newer is decided by the jar, the visit stamp and the host they are keyed by.
 *
 * Driven through the real jar, the real CookieManager and (for the stamp) the
 * real screen rather than by calling mergeCookies with hand-picked flags, so
 * that hardcoding the flag, flipping the comparison, keying the stamp globally
 * or dropping it altogether all show up here.
 *
 * Each test uses its own host: the visit store is process-wide, exactly as it
 * is in the app.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NovelCookieJarTest {

    private val jar = InMemoryCookieJar()

    @Before
    fun acceptCookies() {
        CookieManager.getInstance().setAcceptCookie(true)
    }

    @Test
    fun `a sign-in on this host beats the cookie we already held`() {
        val url = "https://signin.test/".toHttpUrl()
        jar.saveFromResponse(url, listOf(cookie(url, "PHPSESSID", "guest")))
        tick()
        setWebViewCookie(url, "PHPSESSID", "signed-in")
        WebViewVisits.record(url.host)

        assertEquals("signed-in", valueOf(jar.loadForRequest(url), "PHPSESSID"))
    }

    @Test
    fun `a sign-in on one host leaves another host alone`() {
        // The regression this guards: one shared visit stamp let a sign-in on
        // any source hand the WebView's stale copy the win on every other.
        val other = "https://other.test/".toHttpUrl()
        jar.saveFromResponse(other, listOf(cookie(other, "cf_clearance", "fresh")))
        tick()
        setWebViewCookie(other, "cf_clearance", "stale")
        WebViewVisits.record("visited.test")

        assertEquals("fresh", valueOf(jar.loadForRequest(other), "cf_clearance"))
    }

    @Test
    fun `a response after the visit takes precedence straight back`() {
        // The Cloudflare guarantee: a clearance that came off one of our own
        // responses is never shadowed by an older WebView copy.
        val url = "https://reclaim.test/".toHttpUrl()
        setWebViewCookie(url, "cf_clearance", "stale")
        WebViewVisits.record(url.host)
        tick()
        jar.saveFromResponse(url, listOf(cookie(url, "cf_clearance", "fresh")))

        assertEquals("fresh", valueOf(jar.loadForRequest(url), "cf_clearance"))
    }

    @Test
    fun `a name only the WebView holds is sent either way`() {
        val url = "https://extra.test/".toHttpUrl()
        jar.saveFromResponse(url, listOf(cookie(url, "ours", "1")))
        setWebViewCookie(url, "theirs", "2")

        val sent = jar.loadForRequest(url)
        assertEquals("1", valueOf(sent, "ours"))
        assertEquals("2", valueOf(sent, "theirs"))
    }

    @Test
    fun `closing the screen stamps the host it was opened for`() {
        // The one Activity-driven case here: everything above is worthless if
        // nothing ever records a visit.
        val intent = SourceWebViewActivity.intentFor(
            ApplicationProvider.getApplicationContext(),
            "https://closed.test/",
            stayOpen = true,
        )
        Robolectric.buildActivity(SourceWebViewActivity::class.java, intent).setup().destroy()

        assertTrue(WebViewVisits.isNewerThan("closed.test", 0L))
        assertFalse(WebViewVisits.isNewerThan("unopened.test", 0L))
    }

    private fun tick() = ShadowSystemClock.advanceBy(Duration.ofMillis(10))

    private fun cookie(url: okhttp3.HttpUrl, name: String, value: String) =
        Cookie.Builder().name(name).value(value).domain(url.host).build()

    private fun setWebViewCookie(url: okhttp3.HttpUrl, name: String, value: String) {
        CookieManager.getInstance().setCookie(url.toString(), "$name=$value")
    }

    private fun valueOf(cookies: List<Cookie>, name: String) =
        cookies.single { it.name == name }.value
}
