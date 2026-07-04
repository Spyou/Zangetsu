/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Adapted from the Aniyomi project (https://github.com/aniyomiorg/aniyomi)
 * for host-side JSON serialisation in the Zangetsu app.
 */
package com.spyou.watch_app.aniyomi

import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import okhttp3.Headers
import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure serialisation helpers that convert Aniyomi model objects into the JSON
 * shapes consumed by the Dart [AniyomiMapping] layer.
 *
 * All keys are the exact strings the Dart side expects — do NOT rename without
 * updating [aniyomi_mapping.dart] on the Flutter side.
 */
object AniyomiJson {

    // -------------------------------------------------------------------------
    // SAnime
    // -------------------------------------------------------------------------

    /**
     * Serialises a single [SAnime] to a [JSONObject].
     *
     * Dart contract keys: url, title, thumbnail_url, description, genre (comma-separated
     * String), status (Int).
     */
    fun animeToJson(anime: SAnime): JSONObject = JSONObject().apply {
        // url/title are `lateinit` in SAnimeImpl. A getAnimeDetails() parse that
        // fills only metadata (description/genre/…) can leave them uninitialized,
        // and reading an uninitialized lateinit throws — read defensively so
        // detail serialization never crashes.
        put("url", runCatching { anime.url }.getOrDefault(""))
        put("title", runCatching { anime.title }.getOrDefault(""))
        put("thumbnail_url", anime.thumbnail_url ?: JSONObject.NULL)
        put("description", anime.description ?: JSONObject.NULL)
        put("genre", anime.genre ?: JSONObject.NULL)
        put("status", anime.status)
    }

    /**
     * Serialises a list of [SAnime] to a JSON array string.
     *
     * Each element contains: url, title, thumbnail_url.
     * (The list variants are used for browse/search results and only need the
     * lightweight subset. [animeToJson] already includes those keys so the
     * full object is forwarded — Dart ignores extra keys.)
     */
    fun animesToJson(animes: List<SAnime>): String {
        val arr = JSONArray()
        animes.forEach { arr.put(animeToJson(it)) }
        return arr.toString()
    }

    // -------------------------------------------------------------------------
    // SEpisode
    // -------------------------------------------------------------------------

    /**
     * Serialises a single [SEpisode] to a [JSONObject].
     *
     * Dart contract keys: url, name, episode_number (Double; -1.0 when unset),
     * date_upload (Long millis), fillermark (Bool), preview_url (String?).
     */
    fun episodeToJson(ep: SEpisode): JSONObject = JSONObject().apply {
        put("url", ep.url)
        put("name", ep.name)
        // episode_number is Float in the model (-1f when unset); contract demands Double
        put("episode_number", ep.episode_number.toDouble())
        put("date_upload", ep.date_upload)
        put("fillermark", ep.fillermark)
        put("preview_url", ep.preview_url ?: JSONObject.NULL)
    }

    /**
     * Serialises a list of [SEpisode] to a JSON array string.
     */
    fun episodesToJson(episodes: List<SEpisode>): String {
        val arr = JSONArray()
        episodes.forEach { arr.put(episodeToJson(it)) }
        return arr.toString()
    }

    // -------------------------------------------------------------------------
    // Video
    // -------------------------------------------------------------------------

    /**
     * Serialises a single [Video] to a [JSONObject].
     *
     * Dart contract keys:
     *   videoUrl      — the playable stream URL (Video.videoUrl)
     *   videoTitle    — quality label (Video.videoTitle)
     *   headers       — JSON **object** {"Referer":"..."} (NOT a list; converted from OkHttp Headers)
     *   subtitleTracks — array of {url, lang}
     *   audioTracks   — array of {url, lang}
     */
    fun videoToJson(video: Video): JSONObject = JSONObject().apply {
        // Video.videoUrl is nullable — extensions often set only Video.url (the
        // primary field). Fall back to url so the stream is never empty.
        put("videoUrl", video.videoUrl ?: video.url)
        put("videoTitle", video.videoTitle)
        put("headers", headersToJsonObject(video))
        put("subtitleTracks", tracksToJsonArray(video.subtitleTracks))
        put("audioTracks", tracksToJsonArray(video.audioTracks))
    }

    /**
     * Serialises [video] substituting [videoUrlOverride] for the stream URL.
     *
     * Used by [AniyomiBridge] when the playback URL has been routed through a
     * local proxy — the override replaces the raw CDN URL while all other
     * fields (title, headers, tracks) remain unchanged.
     */
    fun videoToJson(video: Video, videoUrlOverride: String): JSONObject = JSONObject().apply {
        put("videoUrl", videoUrlOverride)
        put("videoTitle", video.videoTitle)
        put("headers", headersToJsonObject(video))
        put("subtitleTracks", tracksToJsonArray(video.subtitleTracks))
        put("audioTracks", tracksToJsonArray(video.audioTracks))
    }

    /**
     * Serialises a list of [Video] to a JSON array string.
     */
    fun videosToJson(videos: List<Video>): String {
        val arr = JSONArray()
        videos.forEach { arr.put(videoToJson(it)) }
        return arr.toString()
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /**
     * Converts an OkHttp [Headers] object into a plain JSON object.
     *
     * The contract requires a JSON *object* (not a list of pairs) so that
     * Dart can do `headers['Referer']` directly.
     *
     * Public so callers such as [AniyomiBridge.sourcesJson] can reuse it
     * for source-level default headers (e.g. to deliver Referer/UA for
     * thumbnail image requests).
     */
    fun headersToJsonObject(headers: Headers): JSONObject {
        val obj = JSONObject()
        for (i in 0 until headers.size) {
            obj.put(headers.name(i), headers.value(i))
        }
        return obj
    }

    /**
     * Converts OkHttp [okhttp3.Headers] (or null) on a [Video] into a plain JSON
     * object. The contract requires a JSON *object* (not a list of pairs) so that
     * Dart can do `headers['Referer']` directly.
     */
    private fun headersToJsonObject(video: Video): JSONObject {
        return video.headers?.let { headersToJsonObject(it) } ?: JSONObject()
    }

    /**
     * Converts a list of [eu.kanade.tachiyomi.animesource.model.Track] into a
     * JSON array of {url, lang} objects.
     */
    private fun tracksToJsonArray(tracks: List<eu.kanade.tachiyomi.animesource.model.Track>): JSONArray {
        val arr = JSONArray()
        tracks.forEach { track ->
            arr.put(JSONObject().apply {
                put("url", track.url)
                put("lang", track.lang)
            })
        }
        return arr
    }
}
