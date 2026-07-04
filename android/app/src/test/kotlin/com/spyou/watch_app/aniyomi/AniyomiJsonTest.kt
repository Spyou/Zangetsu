package com.spyou.watch_app.aniyomi

import eu.kanade.tachiyomi.animesource.model.SAnimeImpl
import eu.kanade.tachiyomi.animesource.model.SEpisodeImpl
import eu.kanade.tachiyomi.animesource.model.Track
import eu.kanade.tachiyomi.animesource.model.Video
import okhttp3.Headers
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AniyomiJsonTest {

    // -------------------------------------------------------------------------
    // SAnime serialisation
    // -------------------------------------------------------------------------

    @Test
    fun animeToJson_contains_url_and_title() {
        val anime = SAnimeImpl().apply {
            url = "/a"
            title = "A"
        }
        val json = AniyomiJson.animeToJson(anime)
        assertEquals("/a", json.getString("url"))
        assertEquals("A", json.getString("title"))
    }

    @Test
    fun animeToJson_contains_all_contract_keys() {
        val anime = SAnimeImpl().apply {
            url = "/anime/1"
            title = "Test Anime"
            thumbnail_url = "https://example.com/img.jpg"
            description = "A description"
            genre = "Action, Drama"
            status = 1
        }
        val json = AniyomiJson.animeToJson(anime)
        assertEquals("/anime/1", json.getString("url"))
        assertEquals("Test Anime", json.getString("title"))
        assertEquals("https://example.com/img.jpg", json.getString("thumbnail_url"))
        assertEquals("A description", json.getString("description"))
        assertEquals("Action, Drama", json.getString("genre"))
        assertEquals(1, json.getInt("status"))
    }

    @Test
    fun animesToJson_returns_array_string() {
        val animes = listOf(
            SAnimeImpl().apply { url = "/a1"; title = "Anime 1" },
            SAnimeImpl().apply { url = "/a2"; title = "Anime 2" },
        )
        val json = AniyomiJson.animesToJson(animes)
        val arr = JSONArray(json)
        assertEquals(2, arr.length())
        assertEquals("/a1", arr.getJSONObject(0).getString("url"))
        assertEquals("/a2", arr.getJSONObject(1).getString("url"))
    }

    // -------------------------------------------------------------------------
    // SEpisode serialisation
    // -------------------------------------------------------------------------

    @Test
    fun episodeToJson_contains_contract_keys() {
        val ep = SEpisodeImpl().apply {
            url = "/ep/5"
            name = "Episode 5"
            episode_number = 5f
            date_upload = 1000000L
            fillermark = false
            preview_url = null
        }
        val json = AniyomiJson.episodeToJson(ep)
        assertEquals("/ep/5", json.getString("url"))
        assertEquals("Episode 5", json.getString("name"))
        assertEquals(5.0, json.getDouble("episode_number"), 0.001)
        assertEquals(1000000L, json.getLong("date_upload"))
        assertFalse(json.getBoolean("fillermark"))
        assertTrue(json.isNull("preview_url"))
    }

    @Test
    fun episodesToJson_unset_episode_number_is_negative_one() {
        // SEpisodeImpl defaults episode_number to -1f
        val ep = SEpisodeImpl().apply {
            url = "/ep/x"
            name = "Special"
        }
        val json = AniyomiJson.episodeToJson(ep)
        assertEquals(-1.0, json.getDouble("episode_number"), 0.001)
    }

    // -------------------------------------------------------------------------
    // Video serialisation — headers as JSON object, tracks as arrays
    // -------------------------------------------------------------------------

    @Test
    fun videoToJson_headers_is_json_object_not_list() {
        val headers = Headers.Builder()
            .add("Referer", "https://example.com")
            .add("User-Agent", "test")
            .build()
        val video = Video(
            videoUrl = "https://cdn/stream.m3u8",
            videoTitle = "1080p",
            headers = headers,
        )
        val json = AniyomiJson.videoToJson(video)

        // headers must be a JSONObject, not a JSONArray
        val headersValue = json.get("headers")
        assertTrue("headers must be a JSONObject", headersValue is JSONObject)
        val headersObj = json.getJSONObject("headers")
        assertEquals("https://example.com", headersObj.getString("Referer"))
        assertEquals("test", headersObj.getString("User-Agent"))
    }

    @Test
    fun videoToJson_null_headers_produces_empty_object() {
        val video = Video(
            videoUrl = "https://cdn/stream.mp4",
            videoTitle = "720p",
            headers = null,
        )
        val json = AniyomiJson.videoToJson(video)
        val headersObj = json.getJSONObject("headers")
        assertEquals(0, headersObj.length())
    }

    @Test
    fun videoToJson_subtitleTracks_is_array_with_url_and_lang() {
        val subs = listOf(
            Track(url = "https://subs/en.vtt", lang = "English"),
            Track(url = "https://subs/jp.vtt", lang = "Japanese"),
        )
        val video = Video(
            videoUrl = "https://cdn/v.m3u8",
            videoTitle = "720p",
            subtitleTracks = subs,
        )
        val json = AniyomiJson.videoToJson(video)

        val subsArr = json.getJSONArray("subtitleTracks")
        assertEquals(2, subsArr.length())
        assertEquals("https://subs/en.vtt", subsArr.getJSONObject(0).getString("url"))
        assertEquals("English", subsArr.getJSONObject(0).getString("lang"))
        assertEquals("Japanese", subsArr.getJSONObject(1).getString("lang"))
    }

    @Test
    fun videoToJson_audioTracks_is_array() {
        val audio = listOf(Track(url = "https://audio/ja.m3u8", lang = "Japanese"))
        val video = Video(
            videoUrl = "https://cdn/v.m3u8",
            videoTitle = "720p",
            audioTracks = audio,
        )
        val json = AniyomiJson.videoToJson(video)
        val audioArr = json.getJSONArray("audioTracks")
        assertEquals(1, audioArr.length())
        assertEquals("Japanese", audioArr.getJSONObject(0).getString("lang"))
    }

    @Test
    fun videosToJson_returns_array_string() {
        val videos = listOf(
            Video(videoUrl = "https://cdn/1080.m3u8", videoTitle = "1080p"),
            Video(videoUrl = "https://cdn/720.m3u8", videoTitle = "720p"),
        )
        val json = AniyomiJson.videosToJson(videos)
        val arr = JSONArray(json)
        assertEquals(2, arr.length())
        assertEquals("1080p", arr.getJSONObject(0).getString("videoTitle"))
        assertEquals("720p", arr.getJSONObject(1).getString("videoTitle"))
    }

    @Test
    fun videoToJson_videoUrl_field_is_present() {
        val video = Video(
            videoUrl = "https://cdn/episode1.mp4",
            videoTitle = "480p",
        )
        val json = AniyomiJson.videoToJson(video)
        assertEquals("https://cdn/episode1.mp4", json.getString("videoUrl"))
        assertEquals("480p", json.getString("videoTitle"))
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
        val obj = AniyomiJson.headersToJsonObject(headers)
        assertEquals("https://source.example.com/", obj.getString("Referer"))
        assertEquals("Mozilla/5.0", obj.getString("User-Agent"))
        assertEquals(2, obj.length())
    }

    @Test
    fun headersToJsonObject_empty_headers_produces_empty_object() {
        val headers = Headers.Builder().build()
        val obj = AniyomiJson.headersToJsonObject(headers)
        assertEquals(0, obj.length())
    }

    @Test
    fun headersToJsonObject_public_and_video_variant_produce_same_keys() {
        val headers = Headers.Builder()
            .add("Referer", "https://img.example.com/")
            .build()
        val video = Video(
            videoUrl = "https://cdn/v.m3u8",
            videoTitle = "720p",
            headers = headers,
        )
        val fromVideo = AniyomiJson.videoToJson(video).getJSONObject("headers")
        val fromHeaders = AniyomiJson.headersToJsonObject(headers)
        assertEquals(fromVideo.getString("Referer"), fromHeaders.getString("Referer"))
    }
}
