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
 * for host-side MethodChannel bridging in the Zangetsu app.
 */
package com.spyou.watch_app.mihon

import android.content.Context
import android.content.Intent
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.interceptor.CloudflareRequiredException
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapterImpl
import eu.kanade.tachiyomi.source.model.SMangaImpl
import eu.kanade.tachiyomi.source.online.HttpSource
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method

/** logcat tag for everything on the page-image path. */
private const val PAGE_LOG = "MihonPages"

// Serialize getMangaUpdate for a single manga. The newer extension-lib rejects
// concurrent detail fetches ("getMangaUpdate must not be called concurrently for
// same manga") and some sources race into an NPE — yet our getDetails and
// getChapters fire in parallel for one opened title. Keyed by sourceId:url so
// different titles still run concurrently.
private val mihonMangaLocks = java.util.concurrent.ConcurrentHashMap<String, Mutex>()
private fun mihonMangaLock(key: String): Mutex = mihonMangaLocks.getOrPut(key) { Mutex() }

// The real SChapter objects (+ their manga url) returned by getChapters, keyed
// by "$sourceId:$chapterUrl". Newer extensions (Asura) validate getPageList's
// chapter against the manga's freshly-cached getMangaUpdate state and throw
// "Refresh Chapter List" for a bare url-stub; keeping the real objects lets
// getPages re-sync the source and pass the chapter it actually issued.
private class MihonChapterEntry(
    val mangaUrl: String,
    val chapter: eu.kanade.tachiyomi.source.model.SChapter,
)
private val mihonChapterCache =
    java.util.concurrent.ConcurrentHashMap<String, MihonChapterEntry>()

/**
 * Exposes Mihon manga-extension capabilities to the Flutter layer via a
 * [MethodChannel] named "zangetsu/mihon".
 *
 * Structural twin of [com.spyou.watch_app.aniyomi.AniyomiBridge] — deliberately
 * duplicated rather than abstracted, so the (frozen) anime path never has to
 * change for a manga change. All mutable state lives in [MihonSourceManager]
 * and [MihonExtensionLoader]; the bridge itself is stateless.
 *
 * Method surface (mirrors the anime bridge, with the media swap noted):
 *  - `installExtension`   {apkPath:String}
 *  - `loadInstalled`      {dir:String}
 *  - `listSources`
 *  - `getPopular`         {sourceId, page}
 *  - `getLatest`          {sourceId, page}
 *  - `getFilterList`      {sourceId}
 *  - `search`             {sourceId, query, page, filters?}
 *  - `getDetails`         {sourceId, url}
 *  - `getChapters`        {sourceId, url}   ← anime bridge's `getEpisodes`
 *  - `getPages`           {sourceId, url}   ← anime bridge's `getVideoList`
 *  - `getImage`           {sourceId, url}
 *  - `hasSourceSettings`  {sourceId}
 *  - `openSourceSettings` {sourceId}
 *
 * ### Why no `CatalogueSource` cast
 * The anime bridge casts to `AnimeCatalogueSource` because `getPopularAnime` /
 * `getLatestUpdates` / `getSearchAnime` are declared on `AnimeCatalogueSource`,
 * not on `AnimeSource`. The manga tree is shaped differently: `Source` itself
 * declares `getPopularManga`, `getLatestUpdates`, `getSearchManga`,
 * `getMangaUpdate`, `getPageList` **and** `getFilterList` (see
 * `eu.kanade.tachiyomi.source.Source`), and `CatalogueSource` only supplies the
 * default bodies. So a cast would add a rejection path without unlocking a
 * single method — every call below goes through the `Source` interface, and a
 * hypothetical non-catalogue `Source` keeps working instead of being refused.
 *
 * ### Hard casts
 * Nothing here hard-casts. `HttpSource` is reached with `as?` everywhere:
 * `getImage` (which genuinely needs `client`) returns a clean `NO_SOURCE`
 * error to Dart, and `listSources` / `getPages` degrade — empty baseUrl, empty
 * headers, no image-URL resolution — rather than crashing the host process.
 */
class MihonBridge(
    private val context: Context,
    private val scope: CoroutineScope,
) {

    companion object {
        /**
         * The in-flight `solveCloudflare` call's result. Held (not completed)
         * while [MihonCloudflareActivity] is open so the Dart Future only
         * resolves once the user closes the solve WebView — then the browse
         * screen reloads with the fresh cf_clearance cookie. Completed on the
         * main thread from the activity's `onDestroy`.
         */
        private var pendingSolve: MethodChannel.Result? = null

        /** Stores [result] as the pending solve, completing any prior one. */
        fun beginCloudflareSolve(result: MethodChannel.Result) {
            pendingSolve?.let { runCatching { it.success(false) } }
            pendingSolve = result
        }

        /** Completes the pending solve; called from the activity when it closes. */
        fun finishCloudflareSolve() {
            pendingSolve?.let { runCatching { it.success(true) } }
            pendingSolve = null
        }
    }

    /**
     * Attaches this bridge to [channel] by registering a [MethodChannel.MethodCallHandler].
     *
     * Call this once from `MainActivity.configureFlutterEngine`.
     */
    fun attach(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {

                // Load a single extension APK and register it. DexClassLoad +
                // instantiate is heavy — run OFF the platform main thread.
                "installExtension" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath.isNullOrBlank()) {
                        result.error("BAD_ARGS", "apkPath is required", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        val r = MihonExtensionLoader.load(context, File(apkPath))
                        r.getOrNull()?.let(MihonSourceManager::register)
                        withContext(Dispatchers.Main) {
                            r.fold(
                                onSuccess = { result.success(true) },
                                onFailure = { err ->
                                    // newInstance() wraps the real failure in an
                                    // InvocationTargetException whose own message is null,
                                    // so surface the root cause too — otherwise every load
                                    // failure reads as "no source loaded" with nothing to
                                    // go on.
                                    android.util.Log.e("MihonLoad", "extension load failed", err)
                                    val root = generateSequence(err as Throwable) { it.cause }.last()
                                    val detail = "${err::class.java.simpleName}: ${err.message}" +
                                        if (root !== err) {
                                            " | cause: ${root::class.java.simpleName}: ${root.message}"
                                        } else ""
                                    result.error("LOAD", detail, null)
                                },
                            )
                        }
                    }
                }

                // Load every *.apk found in a directory and register them. Runs on
                // IO — this is what the guarded boot re-load calls, and doing the
                // DexClassLoads on the main thread freezes the splash.
                "loadInstalled" -> {
                    val dir = call.argument<String>("dir")
                    if (dir.isNullOrBlank()) {
                        result.error("BAD_ARGS", "dir is required", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        File(dir).listFiles { f -> f.extension == "apk" }?.forEach { apkFile ->
                            MihonExtensionLoader.load(context, apkFile)
                                .getOrNull()
                                ?.let(MihonSourceManager::register)
                        }
                        withContext(Dispatchers.Main) { result.success(true) }
                    }
                }

                // Return a JSON array of all registered sources.
                "listSources" -> result.success(sourcesJson(MihonSourceManager.installed()))

                // Drop the shared HTTP response cache so a pull-to-refresh
                // re-hits the source instead of serving the 10-min-cached JSON.
                // Every source's client shares one Cache (derived from
                // NetworkHelper.client), so evicting via any of them clears it
                // for Mihon AND Aniyomi. No source loaded → nothing to evict.
                "clearHttpCache" -> scope.runReporting(result, "CLEAR_CACHE") {
                    (MihonSourceManager.all().firstOrNull() as? HttpSource)
                        ?.client?.cache?.evictAll()
                    "true"
                }

                // ------------------------------------------------------------------
                // Data methods — each runs on the bridge IO scope and marshals the
                // result back to the platform main thread before calling result.*.
                // ------------------------------------------------------------------

                "getPopular" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val page = call.argument<Int>("page") ?: 1
                    val src = MihonSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.runReporting(result, "POPULAR") {
                        MihonJson.mangasToJson(src.getPopularManga(page).mangas)
                    }
                }

                "getLatest" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val page = call.argument<Int>("page") ?: 1
                    val src = MihonSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.runReporting(result, "LATEST") {
                        MihonJson.mangasToJson(src.getLatestUpdates(page).mangas)
                    }
                }

                "getFilterList" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val src = MihonSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.runReporting(result, "FILTERS") {
                        MihonFilterJson.filterListToJson(src.getFilterList())
                    }
                }

                "search" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val query = call.argument<String>("query") ?: ""
                    val page = call.argument<Int>("page") ?: 1
                    val filtersJson = call.argument<String>("filters")
                    val src = MihonSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.runReporting(result, "SEARCH") {
                        // No user selection still means the source's OWN defaults,
                        // never an empty list. Extensions routinely index into
                        // their filters — `filters.first { it is SortFilter }` and
                        // friends — so an empty FilterList throws
                        // NoSuchElementException("Collection contains no element
                        // matching the predicate") from inside the extension and
                        // search returns nothing. Observed on MangaTaro; upstream
                        // Mihon always passes getFilterList() here too.
                        val fl = src.getFilterList().also {
                            if (!filtersJson.isNullOrBlank()) {
                                MihonFilterJson.applySelectionJson(it, filtersJson)
                            }
                        }
                        MihonJson.mangasToJson(src.getSearchManga(page, query, fl).mangas)
                    }
                }

                // Manga details. The manga API merged details+chapters into a single
                // getMangaUpdate(), so ask for details ONLY — fetchChapters = false
                // means the (CatalogueSource) default never spawns the chapter-list
                // request, so this stays one round trip like the anime bridge's
                // getAnimeDetails.
                "getDetails" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val url = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = MihonSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.runReporting(result, "DETAILS") {
                        val stub = SMangaImpl().apply { this.url = url }
                        val update = mihonMangaLock("$sourceId:$url").withLock {
                            src.getMangaUpdate(
                                manga = stub,
                                chapters = emptyList(),
                                fetchDetails = true,
                                fetchChapters = false,
                            )
                        }
                        // The details parse usually returns metadata without
                        // re-setting url — carry the known input url so Dart keeps
                        // a valid detail/chapter key.
                        MihonJson.mangaToJson(update.manga).apply { put("url", url) }.toString()
                    }
                }

                // Chapter list — the manga analogue of the anime bridge's
                // `getEpisodes`. Mirror image of `getDetails`: fetchDetails = false
                // so the metadata request is skipped.
                "getChapters" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val url = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = MihonSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.runReporting(result, "CHAPTERS") {
                        val stub = SMangaImpl().apply { this.url = url }
                        val update = mihonMangaLock("$sourceId:$url").withLock {
                            src.getMangaUpdate(
                                manga = stub,
                                chapters = emptyList(),
                                fetchDetails = false,
                                fetchChapters = true,
                            )
                        }
                        // Keep the real chapter objects so getPages can re-issue
                        // them (newer extensions reject a bare url-stub).
                        update.chapters.forEach { ch ->
                            mihonChapterCache["$sourceId:${ch.url}"] =
                                MihonChapterEntry(url, ch)
                        }
                        MihonJson.chaptersToJson(update.chapters)
                    }
                }

                // Page list for a chapter — the manga analogue of `getVideoList`.
                //
                // Returns URLs + headers, never bytes (spec Decision 2): a per-page
                // channel round trip for image bytes across a 20-page chapter would
                // be far slower than letting the Dart reader fetch them itself, and
                // the reader already honours per-image headers.
                //
                // Each element is MihonJson.pageToJson plus a "headers" object, with
                // "imageUrl" rewritten to the URL the source itself would request.
                // See [pageDeliveryJson] for the whole derivation.
                "getPages" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    // Dart sends the chapter url under "url", same key as the anime bridge.
                    val chapterUrl = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = MihonSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.runReporting(result, "PAGE_LIST") {
                        val cached = mihonChapterCache["$sourceId:$chapterUrl"]
                        val chapter = cached?.chapter ?: SChapterImpl().apply {
                            this.url = chapterUrl
                            this.name = ""
                        }
                        val pages = try {
                            src.getPageList(chapter)
                        } catch (e: Exception) {
                            // Newer extensions (Asura) require the manga's chapter
                            // list to be freshly cached in the source before
                            // getPageList, else "Refresh Chapter List". Re-run
                            // getMangaUpdate for the manga we saw this chapter under,
                            // then retry with the real chapter object. MangaDex and
                            // other stateless sources succeed above and never hit this.
                            val mangaUrl = cached?.mangaUrl ?: throw e
                            mihonMangaLock("$sourceId:$mangaUrl").withLock {
                                src.getMangaUpdate(
                                    manga = SMangaImpl().apply { this.url = mangaUrl },
                                    chapters = emptyList(),
                                    fetchDetails = false,
                                    fetchChapters = true,
                                )
                            }
                            src.getPageList(cached.chapter)
                        }
                        // Not an HttpSource (local/stub source): no client, no
                        // headersBuilder, nothing to resolve — hand back the raw
                        // page list rather than failing the whole chapter.
                        val http = src as? HttpSource
                        val arr = JSONArray()
                        pages.forEach { page ->
                            // RISK #3: only pay for the second round trip when the
                            // source left imageUrl null.
                            ensureImageUrl(page) { p -> http?.getImageUrl(p) }
                            arr.put(pageDeliveryJson(http, page))
                        }
                        arr.toString()
                    }
                }

                // Fetch image bytes through the source's own OkHttpClient so that any
                // CF session cookies / custom headers carried by that client are used
                // — Flutter's cached_network_image cannot pass Cloudflare. Used for
                // covers/thumbnails, NOT for chapter pages (those go out as URL +
                // headers via getPages — see spec Decision 2). Source-level headers
                // are the right ones here: imageRequest() is page-scoped and a cover
                // has no Page.
                "getImage" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val url = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = MihonSourceManager.get(sourceId) as? HttpSource ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found or not an HTTP source", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            val response = src.client.newCall(GET(url, src.headers)).execute()
                            response.body?.bytes()
                                ?: throw IllegalStateException("empty body for $url")
                        }.fold(
                            onSuccess = { bytes -> withContext(Dispatchers.Main) { result.success(bytes) } },
                            onFailure = { err ->
                                withContext(Dispatchers.Main) {
                                    result.error("IMG_FETCH", "${err::class.java.simpleName}: ${err.message}", null)
                                }
                            },
                        )
                    }
                }

                // Returns the Cookie + User-Agent to attach to chapter-page image
                // requests, so Flutter's image loader (which fetches pages itself,
                // keeping its disk cache) can pass a Cloudflare-gated image host
                // using the cf_clearance a solve stored in the WebView CookieManager.
                "imageCookie" -> {
                    val url = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val cookie = try {
                        android.webkit.CookieManager.getInstance().getCookie(url)
                    } catch (_: Exception) {
                        null
                    }
                    val headers = HashMap<String, String>()
                    if (!cookie.isNullOrBlank()) headers["Cookie"] = cookie
                    headers["User-Agent"] =
                        eu.kanade.tachiyomi.network.NetworkHelper.defaultUserAgentProvider()
                    result.success(headers)
                }

                "hasSourceSettings" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    result.success(MihonSourceManager.get(sourceId) is ConfigurableSource)
                }

                "openSourceSettings" -> {
                    val sourceId = call.sourceId(result) ?: return@setMethodCallHandler
                    val src = MihonSourceManager.get(sourceId)
                    if (src == null) {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    if (src !is ConfigurableSource) {
                        result.error("NO_SETTINGS", "Source $sourceId is not configurable", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(context, MihonSettingsActivity::class.java)
                        .putExtra(MihonSettingsActivity.EXTRA_SOURCE_ID, sourceId)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(true)
                }

                "solveCloudflare" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("BAD_ARGS", "url required", null)
                        return@setMethodCallHandler
                    }
                    // Hold the result until the solve WebView closes (see the
                    // companion object) so Dart can reload only once it's done.
                    beginCloudflareSolve(result)
                    val intent = Intent(context, MihonCloudflareActivity::class.java)
                        .putExtra(MihonCloudflareActivity.EXTRA_URL, url)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                }

                else -> result.notImplemented()
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Source enumeration — every property read here runs third-party extension code
// -----------------------------------------------------------------------------

/** logcat tag for extension code that misbehaves while sources are enumerated. */
private const val SOURCE_LOG = "MihonSources"

/**
 * Runs [block] — a property read that lands in extension code — and degrades to
 * [fallback] instead of propagating, logging under [SOURCE_LOG].
 *
 * Catches [Throwable], not [Exception], on purpose: the failure that motivated
 * this is a `NoClassDefFoundError` (an [Error]) raised when an extension calls a
 * host class we don't provide. `runCatching` already does exactly that.
 *
 * [src] is identified by class name rather than `name` — `name` is itself
 * extension code and may be the thing that's throwing.
 */
private fun <T> degrading(src: Any, what: String, fallback: T, block: () -> T): T =
    runCatching(block).getOrElse { err ->
        android.util.Log.w(SOURCE_LOG, "${src.javaClass.name}: $what threw, degrading", err)
        fallback
    }

/**
 * Serialises [exts]' sources as a JSON array string.
 *
 * Keys: id, name, lang, nsfw, pkg, version, versionCode, baseUrl, headers —
 * identical to the anime bridge's shape so the Dart source model can be a
 * straight copy. `baseUrl` / `headers` are empty for a non-[HttpSource].
 *
 * ### Why everything here is guarded
 * `baseUrl` and `headers` are not our code. `headers` is `by lazy { headersBuilder().build() }`,
 * and `headersBuilder()` is overridden by the extension — MangaDex's, for one,
 * reaches for `eu.kanade.tachiyomi.AppInfo`. This method runs on the platform
 * main thread, so anything it lets escape is a hard process kill, and a single
 * bad source used to take down the whole app before the user ever saw a list.
 * So: per-field degradation first (a source that can't build headers is still
 * worth listing — its covers just won't carry a Referer), and an outer guard per
 * source for the fields with no sensible fallback (`id`/`name`/`lang`), so one
 * unusable source is skipped instead of hiding its siblings.
 */
internal fun sourcesJson(exts: List<MihonLoadedExtension>): String {
    val arr = JSONArray()
    exts.forEach { ext ->
        ext.sources.forEach { src ->
            runCatching {
                JSONObject().apply {
                    put("id", src.id)
                    put("name", src.name)
                    put("lang", src.lang)
                    put("nsfw", ext.nsfw)
                    put("pkg", ext.pkg)
                    put("version", ext.versionName)
                    put("versionCode", ext.versionCode)
                    put("baseUrl", degrading(src, "baseUrl", "") { (src as? HttpSource)?.baseUrl ?: "" })
                    // Source-level headers (Referer/User-Agent) needed by the Dart
                    // layer to fetch cover images without 403s on strict hosts.
                    put("headers", headersJson(src as? HttpSource))
                }
            }.fold(
                onSuccess = { arr.put(it) },
                onFailure = { err ->
                    // No fallback exists for id/name/lang, so this source can't be
                    // listed at all — but the rest of its extension still can.
                    android.util.Log.e(
                        SOURCE_LOG,
                        "${src.javaClass.name} (${ext.pkg}): unlistable, skipping it",
                        err,
                    )
                },
            )
        }
    }
    return arr.toString()
}

/**
 * [src]'s source-level headers as JSON — empty for a non-[HttpSource], and empty
 * (plus a log line) when the extension's own `headersBuilder()` throws.
 */
internal fun headersJson(src: HttpSource?): JSONObject {
    if (src == null) return JSONObject()
    return degrading(src, "headers", JSONObject()) { MihonJson.headersToJsonObject(src.headers) }
}

// -----------------------------------------------------------------------------
// Page delivery — the crux of this bridge (spec RISK #1 and RISK #3)
// -----------------------------------------------------------------------------

/**
 * Cached handle to `HttpSource.imageRequest(Page)`.
 *
 * That method is the *only* place a Mihon source declares how its page images
 * must be fetched — per-source `Referer`, auth tokens, signed query params, even
 * a rewritten host. It is `protected open` in the vendored `HttpSource` (which
 * is verbatim upstream and must not be edited), and the one public method that
 * uses it — `getImage(page)` — downloads the whole image body, which is exactly
 * the byte proxying spec Decision 2 rules out. So reflection is how a caller
 * outside the class hierarchy reads the request without paying for its body.
 *
 * `Method.invoke` dispatches virtually, so an extension that overrides
 * `imageRequest` gets *its* override called, not `HttpSource`'s default.
 */
private val imageRequestMethod: Method? by lazy(LazyThreadSafetyMode.PUBLICATION) {
    runCatching {
        HttpSource::class.java
            .getDeclaredMethod("imageRequest", Page::class.java)
            .apply { isAccessible = true }
    }.getOrElse { err ->
        // Losing this handle is silent and total: every page of every source
        // downgrades to source-level headers, so sources that override
        // imageRequest 403 on every page while sources that don't look fine.
        // Nothing else in the app would ever say so — hence the loud log.
        android.util.Log.e(
            PAGE_LOG,
            "imageRequest() lookup failed — ALL page image headers degraded to source defaults",
            err,
        )
        null
    }
}

/**
 * Returns the [Request] [src] would issue to fetch [page]'s image, or null if
 * that could not be determined.
 *
 * Null happens when the reflective lookup failed, when the source's own
 * `imageRequest` threw, or — the benign case — when [Page.imageUrl] is still
 * null after [ensureImageUrl], because the default body is
 * `GET(page.imageUrl!!, headers)`. Callers must fall back to source-level
 * headers.
 */
internal fun imageRequestOf(src: HttpSource, page: Page): Request? {
    val method = imageRequestMethod ?: return null // already logged, once, at lookup
    return runCatching { method.invoke(src, page) as? Request }.getOrElse { err ->
        val cause = (err as? InvocationTargetException)?.targetException ?: err
        // An unresolved page NPEs on the default body's `page.imageUrl!!`. That's
        // expected and already reported to Dart as imageUrl:null — stay quiet.
        // Anything else is the source's own override failing, which is worth saying.
        val benign = cause is NullPointerException && page.imageUrl.isNullOrBlank()
        if (!benign) {
            android.util.Log.w(PAGE_LOG, "${src.name}: imageRequest() threw for page ${page.index}", cause)
        }
        null
    }
}

/**
 * Guarantees [page] has a usable `imageUrl`, calling [resolve] **only** when it
 * does not (spec RISK #3 — the two-step page URL).
 *
 * Sources come in both shapes: most fill `imageUrl` during `pageListParse` and
 * are ready immediately; the rest return a page with only `url` and expect a
 * second request per page. `HttpSource.getImageUrl(page)` is documented as
 * "only called if [Page.imageUrl] is null" — this function is that guard, so a
 * source that already did the work never pays for a round trip it doesn't need.
 *
 * A blank url counts as unresolved: the default `imageRequest` would otherwise
 * build `GET("")` and throw.
 *
 * Returns true when [resolve] was invoked. Never throws — a failed resolve
 * leaves `imageUrl` null and the page is reported to Dart as unresolved rather
 * than failing the whole chapter.
 */
internal suspend fun ensureImageUrl(page: Page, resolve: suspend (Page) -> String?): Boolean {
    if (!page.imageUrl.isNullOrBlank()) return false
    page.imageUrl = runCatching { resolve(page) }.getOrNull()?.takeIf { it.isNotBlank() }
    return true
}

/**
 * Builds the JSON the Dart reader needs to fetch one page: [MihonJson.pageToJson]
 * plus a `headers` object, with `imageUrl` set to the URL actually requested.
 *
 * Both values are taken from the source's own [imageRequestOf] when available,
 * so a source that overrides `imageRequest` to add a `Referer`, an auth header,
 * or a rewritten URL gets exactly what it asked for. When the request can't be
 * built, we fall back to the page's own `imageUrl` (already in the JSON) plus
 * the source's default headers — which is what `HttpSource.imageRequest` does
 * by default anyway. Those come through [headersJson], because the usual reason
 * [imageRequestOf] returned null is that the default `imageRequest` body touched
 * those very headers and the extension's `headersBuilder()` threw; re-reading
 * them unguarded would fail the whole chapter, whereas an unheadered page still
 * renders on any host that doesn't check.
 *
 * [http] is null for a non-[HttpSource]; then there are no headers to send.
 */
internal fun pageDeliveryJson(http: HttpSource?, page: Page): JSONObject {
    val json = MihonJson.pageToJson(page)
    if (http == null) {
        json.put("headers", JSONObject())
        return json
    }
    val request = imageRequestOf(http, page)
    if (request != null) {
        // Upstream's own doc says an override may "send different headers or
        // request method like POST" (HttpSource.kt:413-417). A body isn't
        // expressible as url+headers and byte-proxying is out (Decision 2), so we
        // can't honour it — but Dart will GET it and get a 405/403/blank page, so
        // at least make that findable in logcat instead of on-device guesswork.
        // ponytail: detect, don't support — revisit only if a real source needs POST.
        if (request.method != "GET") {
            android.util.Log.w(
                PAGE_LOG,
                "${http.name}: imageRequest() is ${request.method}, not GET — " +
                    "only url+headers are sent, so Dart will GET page ${page.index}",
            )
        }
        json.put("imageUrl", request.url.toString())
        json.put("headers", MihonJson.headersToJsonObject(request.headers))
    } else {
        json.put("headers", headersJson(http))
    }
    return json
}

// -----------------------------------------------------------------------------
// Small shared plumbing (private to this file — the anime bridge is untouched)
// -----------------------------------------------------------------------------

/** Reads the "sourceId" argument, reporting BAD_ARGS to Dart when it's missing. */
private fun io.flutter.plugin.common.MethodCall.sourceId(result: MethodChannel.Result): Long? {
    val raw = argument<Number>("sourceId")
    if (raw == null) {
        result.error("BAD_ARGS", "sourceId required", null)
        return null
    }
    return raw.toLong()
}

/**
 * Runs [block] on IO, then hands its String result (or the failure, tagged
 * [errorCode]) back to Dart on the platform main thread.
 */
private fun CoroutineScope.runReporting(
    result: MethodChannel.Result,
    errorCode: String,
    block: suspend () -> String,
) {
    launch(Dispatchers.IO) {
        runCatching { block() }.fold(
            onSuccess = { json -> withContext(Dispatchers.Main) { result.success(json) } },
            onFailure = { err ->
                // Walk the cause chain: a Cloudflare failure may be wrapped by the
                // source or the suspend adapter. When found, report a distinct
                // "CLOUDFLARE" code carrying the URL so the app can offer the
                // visible solve instead of a generic failure.
                val cf = generateSequence(err as Throwable?) { it.cause }
                    .filterIsInstance<CloudflareRequiredException>()
                    .firstOrNull()
                withContext(Dispatchers.Main) {
                    if (cf != null) {
                        result.error("CLOUDFLARE", cf.url, null)
                    } else {
                        result.error(errorCode, "${err::class.java.simpleName}: ${err.message}", null)
                    }
                }
            },
        )
    }
}
