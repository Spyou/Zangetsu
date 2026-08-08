package com.spyou.watch_app.mihon

import eu.kanade.tachiyomi.source.online.HttpSource
import okhttp3.Headers
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Tests for [sourcesJson] — the enumeration that used to hard-crash the app.
 *
 * `HttpSource.headers` is `by lazy { headersBuilder().build() }` and
 * `headersBuilder()` is the *extension's* code. MangaDex's calls
 * `eu.kanade.tachiyomi.AppInfo`, which the host didn't provide, so reading
 * `headers` threw `NoClassDefFoundError` on the platform main thread and killed
 * the process. `AppInfo` now exists, but the guard has to hold for the next
 * extension that reaches for something we don't ship — hence these tests throw
 * exactly that `Error` (not an `Exception`: `catch (e: Exception)` would not
 * have saved us).
 *
 * Separate file from [MihonBridgeTest] on purpose: this class runs under
 * Robolectric so `android.util.Log` is real, while [MihonBridgeTest] relies on
 * `Log` *not* being mocked to prove its quiet path stays quiet.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MihonBridgeSourcesJsonTest {

    @Test
    fun a_source_whose_headers_throw_is_still_listed_and_does_not_hide_its_siblings() {
        val json = JSONArray(sourcesJson(listOf(extensionOf(ThrowingHeaders(), Good()))))

        assertEquals("both sources must survive", 2, json.length())

        val bad = json.getJSONObject(0)
        assertEquals("Throwing headers", bad.getString("name"))
        assertEquals("everything but the headers is still readable", "https://throws.test", bad.getString("baseUrl"))
        assertEquals("unbuildable headers degrade to empty", 0, bad.getJSONObject("headers").length())

        val good = json.getJSONObject(1)
        assertEquals("Good", good.getString("name"))
        assertEquals("https://good.test", good.getString("baseUrl"))
        // The regression that matters most: the guard must not blanket-empty the
        // headers of sources that build them fine.
        assertEquals("zangetsu-test", good.getJSONObject("headers").getString("User-Agent"))
    }

    @Test
    fun a_source_whose_baseUrl_throws_keeps_its_headers() {
        val json = JSONArray(sourcesJson(listOf(extensionOf(ThrowingBaseUrl()))))

        val entry = json.getJSONObject(0)
        assertEquals("", entry.getString("baseUrl"))
        assertEquals("zangetsu-test", entry.getJSONObject("headers").getString("User-Agent"))
    }

    /**
     * `id` is derived from `name`, so a source whose `name` throws has no
     * identity to send Dart and can't be listed at all. It must be dropped on its
     * own, not take the extension's other sources with it.
     */
    @Test
    fun an_unlistable_source_is_skipped_and_its_siblings_are_kept() {
        val json = JSONArray(sourcesJson(listOf(extensionOf(Unlistable(), Good()))))

        assertEquals("only the broken source is dropped", 1, json.length())
        assertEquals("Good", json.getJSONObject(0).getString("name"))
    }

    @Test
    fun extension_metadata_and_source_identity_are_carried_through() {
        val json = JSONArray(sourcesJson(listOf(extensionOf(Good(), ThrowingHeaders()))))

        val entry = json.getJSONObject(0)
        assertEquals("eu.kanade.tachiyomi.extension.test", entry.getString("pkg"))
        assertEquals("1.4.7", entry.getString("version"))
        assertEquals(47L, entry.getLong("versionCode"))
        assertTrue(entry.getBoolean("nsfw"))
        assertEquals("en", entry.getString("lang"))
        assertNotEquals(
            "each source keeps its own generated id",
            entry.getLong("id"),
            json.getJSONObject(1).getLong("id"),
        )
    }

    @Test
    fun no_extensions_serialises_to_an_empty_array() {
        assertEquals("[]", sourcesJson(emptyList()))
    }

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    private fun extensionOf(vararg sources: HttpSource) = MihonLoadedExtension(
        pkg = "eu.kanade.tachiyomi.extension.test",
        versionName = "1.4.7",
        versionCode = 47L,
        libVersion = 1.4,
        nsfw = true,
        sources = sources.toList(),
    )

    private class Good : HttpSource() {
        override val baseUrl = "https://good.test"
        override val name = "Good"
        override val lang = "en"
        override val supportsLatest = true
        override fun headersBuilder(): Headers.Builder =
            Headers.Builder().add("User-Agent", "zangetsu-test")
    }

    /** MangaDex's exact failure shape: a host class the extension links against is absent. */
    private class ThrowingHeaders : HttpSource() {
        override val baseUrl = "https://throws.test"
        override val name = "Throwing headers"
        override val lang = "en"
        override val supportsLatest = false
        override fun headersBuilder(): Headers.Builder =
            throw NoClassDefFoundError("Leu/kanade/tachiyomi/AppInfo;")
    }

    /** Sources that pick their domain from preferences can throw here too. */
    private class ThrowingBaseUrl : HttpSource() {
        override val baseUrl: String get() = error("no domain configured")
        override val name = "Throwing baseUrl"
        override val lang = "en"
        override val supportsLatest = false
        override fun headersBuilder(): Headers.Builder =
            Headers.Builder().add("User-Agent", "zangetsu-test")
    }

    private class Unlistable : HttpSource() {
        override val baseUrl = "https://broken.test"
        override val name: String get() = throw NoClassDefFoundError("Leu/kanade/tachiyomi/AppInfo;")
        override val lang = "en"
        override val supportsLatest = false
        override fun headersBuilder(): Headers.Builder =
            Headers.Builder().add("User-Agent", "zangetsu-test")
    }
}
