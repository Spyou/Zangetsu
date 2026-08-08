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
 * Adapted from the Mihon project (https://github.com/mihonapp/mihon)
 * for host-side JSON serialisation in the Zangetsu app.
 */
package com.spyou.watch_app.mihon

import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import okhttp3.Headers
import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure serialisation helpers that convert Mihon model objects into the JSON
 * shapes the future Dart manga mapping layer consumes.
 *
 * Structural twin of [com.spyou.watch_app.aniyomi.AniyomiJson] for the manga
 * models — kept as a separate copy rather than a shared abstraction so the
 * (untouched) anime path never depends on manga code.
 *
 * All keys are the exact strings a future Dart `mihon_mapping.dart` is
 * expected to use — do NOT rename without updating that file once it exists.
 */
object MihonJson {

    // -------------------------------------------------------------------------
    // SManga
    // -------------------------------------------------------------------------

    /**
     * Serialises a single [SManga] to a [JSONObject].
     *
     * Dart contract keys: url, title, thumbnail_url, description, genre
     * (comma-separated String), status (Int), author, artist.
     */
    fun mangaToJson(manga: SManga): JSONObject = JSONObject().apply {
        // url AND title are BOTH `lateinit` in SMangaImpl — unlike SAnimeImpl,
        // where only `url` is truly lateinit (title defaults to ""). A
        // getMangaDetails() parse that fills only metadata (description/genre/…)
        // can leave either uninitialized, and reading an uninitialized lateinit
        // throws — read both defensively so detail serialization never crashes.
        put("url", runCatching { manga.url }.getOrDefault(""))
        put("title", runCatching { manga.title }.getOrDefault(""))
        put("thumbnail_url", manga.thumbnail_url ?: JSONObject.NULL)
        put("description", manga.description ?: JSONObject.NULL)
        put("genre", manga.genre ?: JSONObject.NULL)
        put("status", manga.status)
        put("author", manga.author ?: JSONObject.NULL)
        put("artist", manga.artist ?: JSONObject.NULL)
    }

    /**
     * Serialises a list of [SManga] to a JSON array string.
     *
     * Each element contains the full [mangaToJson] shape — Dart ignores extra
     * keys, so the same object serves both browse/search rows and the detail
     * screen.
     */
    fun mangasToJson(mangas: List<SManga>): String {
        val arr = JSONArray()
        mangas.forEach { arr.put(mangaToJson(it)) }
        return arr.toString()
    }

    // -------------------------------------------------------------------------
    // SChapter
    // -------------------------------------------------------------------------

    /**
     * Serialises a single [SChapter] to a [JSONObject].
     *
     * Dart contract keys: url, name, chapter_number (Double; -1.0 when unset),
     * date_upload (Long millis), scanlator (String?).
     *
     * SChapter has no fillermark/preview_url/summary equivalent — those are
     * anime-only concepts absent from the manga model — and its only field
     * SEpisode doesn't have is `memo`, which (like [SManga.memo]) is
     * source-private metadata "not visible to users" and intentionally not
     * serialised here.
     */
    fun chapterToJson(chapter: SChapter): JSONObject = JSONObject().apply {
        // url/name are `lateinit` in SChapterImpl, same shape as SEpisodeImpl —
        // read defensively for the same reason as mangaToJson above.
        put("url", runCatching { chapter.url }.getOrDefault(""))
        put("name", runCatching { chapter.name }.getOrDefault(""))
        // chapter_number is Float in the model (-1f when unset); contract demands Double
        put("chapter_number", chapter.chapter_number.toDouble())
        put("date_upload", chapter.date_upload)
        put("scanlator", chapter.scanlator ?: JSONObject.NULL)
    }

    /**
     * Serialises a list of [SChapter] to a JSON array string.
     */
    fun chaptersToJson(chapters: List<SChapter>): String {
        val arr = JSONArray()
        chapters.forEach { arr.put(chapterToJson(it)) }
        return arr.toString()
    }

    // -------------------------------------------------------------------------
    // Page
    // -------------------------------------------------------------------------

    /**
     * Serialises a single [Page] to a [JSONObject].
     *
     * Dart contract keys:
     *   index    — 0-based page position (Page.index)
     *   url      — the page's (web) URL, as returned by fetchPageList
     *   imageUrl — the direct image URL, or JSON **null** when not yet resolved
     *
     * [Page] is not [eu.kanade.tachiyomi.animesource.model.Video]: it carries
     * no headers of its own (image-request headers come from the source — see
     * [headersToJsonObject]), and it represents "image URL known" vs. "needs a
     * second resolve" purely through `imageUrl`'s nullability, mirroring the
     * exact convention `HttpSource` itself uses — its `getImageUrl(page)` doc
     * states it "is only called if Page.imageUrl is null":
     *   - imageUrl present → ready to load directly from that URL.
     *   - imageUrl is null → the bridge must resolve it (source.getImageUrl /
     *     fetchImageUrl) before the page can be displayed. This class performs
     *     no such resolution and no byte-proxying — that's the bridge's job.
     */
    fun pageToJson(page: Page): JSONObject = JSONObject().apply {
        put("index", page.index)
        put("url", page.url)
        put("imageUrl", page.imageUrl ?: JSONObject.NULL)
    }

    /**
     * Serialises a list of [Page] to a JSON array string.
     */
    fun pagesToJson(pages: List<Page>): String {
        val arr = JSONArray()
        pages.forEach { arr.put(pageToJson(it)) }
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
     * Public so a future manga bridge can attach a source's default request
     * headers to page-image delivery — [Page] carries no headers of its own
     * (see [pageToJson]), so headers travel alongside the page list rather
     * than inside it, same as [com.spyou.watch_app.aniyomi.AniyomiJson] does
     * for source-level thumbnail headers.
     */
    fun headersToJsonObject(headers: Headers): JSONObject {
        val obj = JSONObject()
        for (i in 0 until headers.size) {
            obj.put(headers.name(i), headers.value(i))
        }
        return obj
    }
}
