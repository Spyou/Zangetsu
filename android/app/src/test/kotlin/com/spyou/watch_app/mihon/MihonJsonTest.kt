package com.spyou.watch_app.mihon

import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapterImpl
import eu.kanade.tachiyomi.source.model.SMangaImpl
import okhttp3.Headers
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MihonJsonTest {

    // -------------------------------------------------------------------------
    // SManga serialisation
    // -------------------------------------------------------------------------

    @Test
    fun mangaToJson_contains_url_and_title() {
        val manga = SMangaImpl().apply {
            url = "/m"
            title = "M"
        }
        val json = MihonJson.mangaToJson(manga)
        assertEquals("/m", json.getString("url"))
        assertEquals("M", json.getString("title"))
    }

    @Test
    fun mangaToJson_contains_all_contract_keys() {
        val manga = SMangaImpl().apply {
            url = "/manga/1"
            title = "Test Manga"
            thumbnail_url = "https://example.com/cover.jpg"
            description = "A description"
            genre = "Action, Drama"
            status = 1
            author = "Some Author"
            artist = "Some Artist"
        }
        val json = MihonJson.mangaToJson(manga)
        assertEquals("/manga/1", json.getString("url"))
        assertEquals("Test Manga", json.getString("title"))
        assertEquals("https://example.com/cover.jpg", json.getString("thumbnail_url"))
        assertEquals("A description", json.getString("description"))
        assertEquals("Action, Drama", json.getString("genre"))
        assertEquals(1, json.getInt("status"))
        assertEquals("Some Author", json.getString("author"))
        assertEquals("Some Artist", json.getString("artist"))
    }

    @Test
    fun mangaToJson_null_optional_fields_are_json_null() {
        val manga = SMangaImpl().apply {
            url = "/manga/2"
            title = "Bare Manga"
            // thumbnail_url, description, genre, author, artist left at their
            // SMangaImpl defaults (null)
        }
        val json = MihonJson.mangaToJson(manga)
        assertTrue(json.isNull("thumbnail_url"))
        assertTrue(json.isNull("description"))
        assertTrue(json.isNull("genre"))
        assertTrue(json.isNull("author"))
        assertTrue(json.isNull("artist"))
    }

    @Test
    fun mangaToJson_partially_populated_manga_does_not_throw_on_uninitialized_lateinit() {
        // url/title are `lateinit` in SMangaImpl. A getMangaDetails() parse that
        // only fills metadata (leaving url/title untouched, as a real extension
        // would when the manga was already known from a browse/search result)
        // must not throw when serialised.
        val manga = SMangaImpl().apply {
            description = "Only metadata was parsed"
            genre = "Comedy"
            status = 2
            // url and title are intentionally never assigned
        }
        val json = MihonJson.mangaToJson(manga)
        assertEquals("", json.getString("url"))
        assertEquals("", json.getString("title"))
        assertEquals("Only metadata was parsed", json.getString("description"))
        assertEquals("Comedy", json.getString("genre"))
        assertEquals(2, json.getInt("status"))
    }

    @Test
    fun mangasToJson_returns_array_string() {
        val mangas = listOf(
            SMangaImpl().apply { url = "/m1"; title = "Manga 1" },
            SMangaImpl().apply { url = "/m2"; title = "Manga 2" },
        )
        val json = MihonJson.mangasToJson(mangas)
        val arr = JSONArray(json)
        assertEquals(2, arr.length())
        assertEquals("/m1", arr.getJSONObject(0).getString("url"))
        assertEquals("/m2", arr.getJSONObject(1).getString("url"))
    }

    @Test
    fun mangasToJson_empty_list_returns_empty_array() {
        val json = MihonJson.mangasToJson(emptyList())
        val arr = JSONArray(json)
        assertEquals(0, arr.length())
    }

    // -------------------------------------------------------------------------
    // SChapter serialisation
    // -------------------------------------------------------------------------

    @Test
    fun chapterToJson_contains_contract_keys() {
        val chapter = SChapterImpl().apply {
            url = "/ch/5"
            name = "Chapter 5"
            chapter_number = 5f
            date_upload = 1000000L
            scanlator = "Some Group"
        }
        val json = MihonJson.chapterToJson(chapter)
        assertEquals("/ch/5", json.getString("url"))
        assertEquals("Chapter 5", json.getString("name"))
        assertEquals(5.0, json.getDouble("chapter_number"), 0.001)
        assertEquals(1000000L, json.getLong("date_upload"))
        assertEquals("Some Group", json.getString("scanlator"))
    }

    @Test
    fun chapterToJson_unset_chapter_number_is_negative_one() {
        // SChapterImpl defaults chapter_number to -1f
        val chapter = SChapterImpl().apply {
            url = "/ch/x"
            name = "Special"
        }
        val json = MihonJson.chapterToJson(chapter)
        assertEquals(-1.0, json.getDouble("chapter_number"), 0.001)
    }

    @Test
    fun chapterToJson_null_scanlator_is_json_null() {
        val chapter = SChapterImpl().apply {
            url = "/ch/6"
            name = "Chapter 6"
        }
        val json = MihonJson.chapterToJson(chapter)
        assertTrue(json.isNull("scanlator"))
    }

    @Test
    fun chapterToJson_partially_populated_chapter_does_not_throw_on_uninitialized_lateinit() {
        // url/name are `lateinit` in SChapterImpl, same shape as SEpisodeImpl.
        val chapter = SChapterImpl().apply {
            chapter_number = 3f
            // url and name are intentionally never assigned
        }
        val json = MihonJson.chapterToJson(chapter)
        assertEquals("", json.getString("url"))
        assertEquals("", json.getString("name"))
        assertEquals(3.0, json.getDouble("chapter_number"), 0.001)
    }

    @Test
    fun chaptersToJson_returns_array_string() {
        val chapters = listOf(
            SChapterImpl().apply { url = "/c1"; name = "Chapter 1" },
            SChapterImpl().apply { url = "/c2"; name = "Chapter 2" },
        )
        val json = MihonJson.chaptersToJson(chapters)
        val arr = JSONArray(json)
        assertEquals(2, arr.length())
        assertEquals("/c1", arr.getJSONObject(0).getString("url"))
        assertEquals("/c2", arr.getJSONObject(1).getString("url"))
    }

    @Test
    fun chaptersToJson_empty_list_returns_empty_array() {
        val json = MihonJson.chaptersToJson(emptyList())
        val arr = JSONArray(json)
        assertEquals(0, arr.length())
    }

    // -------------------------------------------------------------------------
    // Page serialisation — imageUrl nullability distinguishes resolved vs.
    // needs-a-second-resolve pages
    // -------------------------------------------------------------------------

    @Test
    fun pageToJson_imageUrl_present_means_ready_to_load() {
        val page = Page(index = 0, url = "/page/1", imageUrl = "https://cdn/img1.jpg")
        val json = MihonJson.pageToJson(page)
        assertEquals(0, json.getInt("index"))
        assertEquals("/page/1", json.getString("url"))
        assertEquals("https://cdn/img1.jpg", json.getString("imageUrl"))
    }

    @Test
    fun pageToJson_imageUrl_null_means_needs_resolution() {
        // Many sources return only Page.url and need a second fetchImageUrl call
        // (HttpSource.getImageUrl is documented as "only called if Page.imageUrl
        // is null"). The JSON must preserve that null so the bridge knows to
        // resolve rather than load directly.
        val page = Page(index = 2, url = "/page/3", imageUrl = null)
        val json = MihonJson.pageToJson(page)
        assertEquals(2, json.getInt("index"))
        assertEquals("/page/3", json.getString("url"))
        assertTrue("imageUrl must be JSON null when unresolved", json.isNull("imageUrl"))
    }

    @Test
    fun pagesToJson_returns_array_string_with_mixed_resolution_states() {
        val pages = listOf(
            Page(index = 0, url = "/p0", imageUrl = "https://cdn/0.jpg"),
            Page(index = 1, url = "/p1", imageUrl = null),
        )
        val json = MihonJson.pagesToJson(pages)
        val arr = JSONArray(json)
        assertEquals(2, arr.length())
        assertEquals("https://cdn/0.jpg", arr.getJSONObject(0).getString("imageUrl"))
        assertTrue(arr.getJSONObject(1).isNull("imageUrl"))
    }

    @Test
    fun pagesToJson_empty_list_returns_empty_array() {
        val json = MihonJson.pagesToJson(emptyList())
        val arr = JSONArray(json)
        assertEquals(0, arr.length())
    }

    // -------------------------------------------------------------------------
    // headersToJsonObject(Headers) — public source-level helper
    // -------------------------------------------------------------------------

    @Test
    fun headersToJsonObject_converts_all_pairs_to_json_object() {
        val headers = Headers.Builder()
            .add("Referer", "https://source.example.com/")
            .add("User-Agent", "Mozilla/5.0")
            .build()
        val obj = MihonJson.headersToJsonObject(headers)
        assertEquals("https://source.example.com/", obj.getString("Referer"))
        assertEquals("Mozilla/5.0", obj.getString("User-Agent"))
        assertEquals(2, obj.length())
    }

    @Test
    fun headersToJsonObject_empty_headers_produces_empty_object() {
        val headers = Headers.Builder().build()
        val obj = MihonJson.headersToJsonObject(headers)
        assertEquals(0, obj.length())
    }
}
