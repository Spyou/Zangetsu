package com.spyou.watch_app.mihon

import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.runBlocking
import okhttp3.Headers
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Modifier

/**
 * Unit tests for the parts of [MihonBridge] that are pure logic.
 *
 * The MethodChannel handler itself needs a real Flutter engine and the data
 * methods need a DEX-loaded extension plus network, so those are on-device
 * checks. What IS testable here is the bit most likely to regress silently:
 * the decision of whether a page needs a second round trip to resolve its image
 * URL (spec RISK #3), and the reflective handle onto `HttpSource.imageRequest`
 * that supplies per-source image headers (spec RISK #1).
 */
class MihonBridgeTest {

    // -------------------------------------------------------------------------
    // ensureImageUrl — the two-step page URL decision (RISK #3)
    // -------------------------------------------------------------------------

    @Test
    fun ensureImageUrl_does_not_resolve_when_imageUrl_already_present() = runBlocking {
        val page = Page(index = 0, url = "/page/1", imageUrl = "https://cdn/img1.jpg")
        var calls = 0
        val resolved = ensureImageUrl(page) { calls++; "https://cdn/SHOULD_NOT_BE_USED.jpg" }

        assertFalse("a page with an imageUrl must not trigger a resolve", resolved)
        assertEquals("resolver must not be called at all", 0, calls)
        assertEquals("existing imageUrl must be left untouched", "https://cdn/img1.jpg", page.imageUrl)
    }

    @Test
    fun ensureImageUrl_resolves_exactly_once_when_imageUrl_is_null() = runBlocking {
        val page = Page(index = 3, url = "/page/4", imageUrl = null)
        var calls = 0
        val resolved = ensureImageUrl(page) { p ->
            calls++
            // the resolver receives the page it is resolving
            assertEquals("/page/4", p.url)
            "https://cdn/resolved.jpg"
        }

        assertTrue(resolved)
        assertEquals("exactly one round trip", 1, calls)
        assertEquals("https://cdn/resolved.jpg", page.imageUrl)
    }

    @Test
    fun ensureImageUrl_treats_blank_imageUrl_as_unresolved() = runBlocking {
        val page = Page(index = 0, url = "/p", imageUrl = "")
        val resolved = ensureImageUrl(page) { "https://cdn/real.jpg" }

        assertTrue(resolved)
        assertEquals("https://cdn/real.jpg", page.imageUrl)
    }

    @Test
    fun ensureImageUrl_swallows_a_failing_resolver_and_leaves_imageUrl_null() = runBlocking {
        val page = Page(index = 0, url = "/p", imageUrl = null)
        val resolved = ensureImageUrl(page) { error("source blew up") }

        assertTrue(resolved)
        assertNull("a failed resolve must not fabricate a url", page.imageUrl)
    }

    @Test
    fun ensureImageUrl_rejects_a_blank_resolver_result() = runBlocking {
        val page = Page(index = 0, url = "/p", imageUrl = null)
        ensureImageUrl(page) { "   " }

        assertNull("a blank resolve result must not become the image url", page.imageUrl)
    }

    @Test
    fun ensureImageUrl_handles_a_null_resolver_result_for_non_http_sources() = runBlocking {
        // getPages passes `http?.getImageUrl(p)`, which is null when the source
        // is not an HttpSource — that must not crash or set a bogus url.
        val page = Page(index = 0, url = "/p", imageUrl = null)
        val resolved = ensureImageUrl(page) { null }

        assertTrue(resolved)
        assertNull(page.imageUrl)
    }

    // -------------------------------------------------------------------------
    // imageRequest reflection contract (RISK #1)
    // -------------------------------------------------------------------------

    /**
     * [imageRequestOf] reaches `HttpSource.imageRequest(Page)` reflectively
     * because the method is `protected`. If the vendored HttpSource is ever
     * re-pinned to an upstream revision that renames it, changes its parameter,
     * or changes its return type, the lookup silently returns null and EVERY
     * page quietly downgrades to source-level headers — 403s on any source that
     * customises its image request. This test is that canary.
     */
    @Test
    fun httpSource_still_declares_the_imageRequest_method_reflection_depends_on() {
        // throws NoSuchMethodException (failing the test) if the signature moved
        val method = HttpSource::class.java.getDeclaredMethod("imageRequest", Page::class.java)

        assertEquals(
            "imageRequest must still return an okhttp Request",
            Request::class.java,
            method.returnType,
        )
        assertTrue(
            "imageRequest is expected to be protected — that is why reflection is needed",
            Modifier.isProtected(method.modifiers),
        )
        assertFalse(
            "imageRequest must be an instance method so Method.invoke dispatches to overrides",
            Modifier.isStatic(method.modifiers),
        )
    }

    /**
     * The one that actually guards the runtime path.
     *
     * The signature test above re-derives its own lookup and never calls
     * [imageRequestOf], so it proves the vendored method exists — not that our
     * reflection reaches it. This one drives the real code against a source that
     * overrides `imageRequest`, and fails if the handle is ever null (e.g. a
     * typo'd method name), which is otherwise a completely silent degradation.
     */
    @Test
    fun imageRequestOf_dispatches_to_the_sources_own_override() {
        val page = Page(index = 7, url = "/p/7", imageUrl = "https://cdn.test/plain/7.jpg")

        val request = imageRequestOf(OverridingSource(), page)

        assertNotNull("reflection must reach the source's imageRequest", request)
        assertEquals(
            "must be the OVERRIDE's url, not page.imageUrl",
            "https://cdn.test/override/7.jpg",
            request!!.url.toString(),
        )
        assertEquals(
            "the override's per-source Referer is the whole point of RISK #1",
            "https://example.test/reader",
            request.header("Referer"),
        )
    }

    @Test
    fun pageDeliveryJson_emits_the_overrides_url_and_headers() {
        val page = Page(index = 7, url = "/p/7", imageUrl = "https://cdn.test/plain/7.jpg")

        val json = pageDeliveryJson(OverridingSource(), page)

        assertEquals("https://cdn.test/override/7.jpg", json.getString("imageUrl"))
        assertEquals(
            "https://example.test/reader",
            json.getJSONObject("headers").getString("Referer"),
        )
    }

    /**
     * The benign branch: an unresolved page NPEs inside the *default*
     * `imageRequest` body (`GET(page.imageUrl!!, headers)`). That is expected and
     * must stay out of logcat, or every such page spams a warning.
     *
     * This test doubles as the assertion that it stays quiet: `android.util.Log`
     * is not mocked on the JVM, so if the benign guard ever stops matching, the
     * `Log.w` fires and this test dies on "Log not mocked".
     */
    @Test
    fun imageRequestOf_returns_null_and_stays_quiet_for_an_unresolved_page() {
        val page = Page(index = 0, url = "/p/0", imageUrl = null)

        assertNull(imageRequestOf(PlainSource(), page))
    }

    /** [HttpSource] with no `imageRequest` override — exercises the default body. */
    private class PlainSource : HttpSource() {
        override val baseUrl = "https://plain.test"
        override val name = "Plain"
        override val lang = "en"
        override val supportsLatest = false

        override fun headersBuilder(): Headers.Builder =
            Headers.Builder().add("User-Agent", "zangetsu-test")
    }

    /**
     * Minimal real [HttpSource] that overrides `imageRequest` — the shape this
     * whole mechanism exists for.
     *
     * No Robolectric and no Injekt needed: `HttpSource.network` is
     * `by injectLazy()` so the constructor resolves nothing, and overriding
     * [headersBuilder] avoids the default body's `network.defaultUserAgentProvider()`.
     */
    private class OverridingSource : HttpSource() {
        override val baseUrl = "https://example.test"
        override val name = "Overriding"
        override val lang = "en"
        override val supportsLatest = false

        override fun headersBuilder(): Headers.Builder =
            Headers.Builder().add("User-Agent", "zangetsu-test")

        override fun imageRequest(page: Page): Request = Request.Builder()
            .url("https://cdn.test/override/${page.index}.jpg")
            .header("Referer", "$baseUrl/reader")
            .build()
    }

    // -------------------------------------------------------------------------
    // pageDeliveryJson — non-HttpSource branch
    // -------------------------------------------------------------------------

    @Test
    fun pageDeliveryJson_for_a_non_http_source_keeps_the_page_url_and_sends_empty_headers() {
        val page = Page(index = 2, url = "/page/3", imageUrl = "https://cdn/3.jpg")
        val json = pageDeliveryJson(http = null, page = page)

        assertEquals(2, json.getInt("index"))
        assertEquals("/page/3", json.getString("url"))
        assertEquals("https://cdn/3.jpg", json.getString("imageUrl"))
        assertEquals("no source means no headers to send", 0, json.getJSONObject("headers").length())
    }

    @Test
    fun pageDeliveryJson_for_a_non_http_source_reports_an_unresolved_page_as_json_null() {
        val page = Page(index = 0, url = "/page/1", imageUrl = null)
        val json = pageDeliveryJson(http = null, page = page)

        assertTrue("unresolved pages must reach Dart as null, not \"null\"", json.isNull("imageUrl"))
    }
}
