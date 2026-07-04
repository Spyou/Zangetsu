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
 * for host-side MethodChannel bridging in the Zangetsu app.
 */
package com.spyou.watch_app.aniyomi

import android.content.Context
import eu.kanade.tachiyomi.animesource.AnimeCatalogueSource
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.SAnimeImpl
import eu.kanade.tachiyomi.animesource.model.SEpisodeImpl
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.network.GET
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Exposes Aniyomi extension capabilities to the Flutter layer via a
 * [MethodChannel] named "zangetsu/aniyomi".
 *
 * The bridge is intentionally stateless — all mutable state lives in
 * [AniyomiSourceManager] and [AniyomiExtensionLoader]. Handlers that need
 * network work should be extended in later tasks using [scope] for suspend
 * coroutines; the current operations (load/list) are synchronous.
 *
 * Supported methods:
 *  - `installExtension` {apkPath:String} — loads and registers an APK.
 *  - `loadInstalled`    {dir:String}     — loads every `*.apk` in a directory.
 *  - `listSources`                       — returns a JSON array string.
 *
 * Later tasks add data methods (`getPopular`, `getDetails`, etc.) inside the
 * same `when(call.method)` block to keep the handler extensible.
 */
class AniyomiBridge(
    private val context: Context,
    @Suppress("unused") private val scope: CoroutineScope,
) {

    /**
     * Attaches this bridge to [channel] by registering a [MethodChannel.MethodCallHandler].
     *
     * Call this once from [MainActivity.configureFlutterEngine].
     */
    fun attach(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {

                // Load a single extension APK and register it. DexClassLoad +
                // instantiate is heavy — run OFF the platform main thread (calling
                // it inline froze the splash on boot re-load).
                "installExtension" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath.isNullOrBlank()) {
                        result.error("BAD_ARGS", "apkPath is required", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        val r = AniyomiExtensionLoader.load(context, File(apkPath))
                        r.getOrNull()?.let(AniyomiSourceManager::register)
                        withContext(Dispatchers.Main) {
                            r.fold(
                                onSuccess = { result.success(true) },
                                onFailure = { err -> result.error("LOAD", err.message, null) },
                            )
                        }
                    }
                }

                // Load every *.apk found in a directory and register them. Runs on
                // IO — this is what the guarded boot re-load calls, and doing the
                // DexClassLoads on the main thread froze the splash.
                "loadInstalled" -> {
                    val dir = call.argument<String>("dir")
                    if (dir.isNullOrBlank()) {
                        result.error("BAD_ARGS", "dir is required", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        File(dir).listFiles { f -> f.extension == "apk" }?.forEach { apkFile ->
                            AniyomiExtensionLoader.load(context, apkFile)
                                .getOrNull()
                                ?.let(AniyomiSourceManager::register)
                        }
                        withContext(Dispatchers.Main) { result.success(true) }
                    }
                }

                // Return a JSON array of all registered sources.
                "listSources" -> result.success(sourcesJson())

                // ------------------------------------------------------------------
                // Data methods — each runs on the bridge IO scope and marshals the
                // result back to the platform main thread before calling result.*.
                // ------------------------------------------------------------------

                "getPopular" -> {
                    val sourceId = (call.argument<Number>("sourceId") ?: run {
                        result.error("BAD_ARGS", "sourceId required", null); return@setMethodCallHandler
                    }).toLong()
                    val page = call.argument<Int>("page") ?: 1
                    val src = AniyomiSourceManager.get(sourceId) as? AnimeCatalogueSource ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found or not a catalogue source", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            val page2 = src.getPopularAnime(page)
                            AniyomiJson.animesToJson(page2.animes)
                        }.fold(
                            onSuccess = { json -> withContext(Dispatchers.Main) { result.success(json) } },
                            onFailure = { err -> withContext(Dispatchers.Main) { result.error("POPULAR", "${err::class.java.simpleName}: ${err.message}", null) } },
                        )
                    }
                }

                "getLatest" -> {
                    val sourceId = (call.argument<Number>("sourceId") ?: run {
                        result.error("BAD_ARGS", "sourceId required", null); return@setMethodCallHandler
                    }).toLong()
                    val page = call.argument<Int>("page") ?: 1
                    val src = AniyomiSourceManager.get(sourceId) as? AnimeCatalogueSource ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found or not a catalogue source", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            val page2 = src.getLatestUpdates(page)
                            AniyomiJson.animesToJson(page2.animes)
                        }.fold(
                            onSuccess = { json -> withContext(Dispatchers.Main) { result.success(json) } },
                            onFailure = { err -> withContext(Dispatchers.Main) { result.error("LATEST", "${err::class.java.simpleName}: ${err.message}", null) } },
                        )
                    }
                }

                "search" -> {
                    val sourceId = (call.argument<Number>("sourceId") ?: run {
                        result.error("BAD_ARGS", "sourceId required", null); return@setMethodCallHandler
                    }).toLong()
                    val query = call.argument<String>("query") ?: ""
                    val page = call.argument<Int>("page") ?: 1
                    val src = AniyomiSourceManager.get(sourceId) as? AnimeCatalogueSource ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found or not a catalogue source", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            // filtersJson (Task 10) is not yet parsed — pass empty filter list
                            val page2 = src.getSearchAnime(page, query, AnimeFilterList())
                            AniyomiJson.animesToJson(page2.animes)
                        }.fold(
                            onSuccess = { json -> withContext(Dispatchers.Main) { result.success(json) } },
                            onFailure = { err -> withContext(Dispatchers.Main) { result.error("SEARCH", "${err::class.java.simpleName}: ${err.message}", null) } },
                        )
                    }
                }

                "getDetails" -> {
                    val sourceId = (call.argument<Number>("sourceId") ?: run {
                        result.error("BAD_ARGS", "sourceId required", null); return@setMethodCallHandler
                    }).toLong()
                    val url = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = AniyomiSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            val stub = SAnimeImpl().apply { this.url = url }
                            val details = src.getAnimeDetails(stub)
                            // getAnimeDetails() usually returns metadata without
                            // re-setting url — carry the known input url so Dart
                            // keeps a valid detail/episode key.
                            AniyomiJson.animeToJson(details).apply { put("url", url) }.toString()
                        }.fold(
                            onSuccess = { json -> withContext(Dispatchers.Main) { result.success(json) } },
                            onFailure = { err -> withContext(Dispatchers.Main) { result.error("DETAILS", "${err::class.java.simpleName}: ${err.message}", null) } },
                        )
                    }
                }

                "getEpisodes" -> {
                    val sourceId = (call.argument<Number>("sourceId") ?: run {
                        result.error("BAD_ARGS", "sourceId required", null); return@setMethodCallHandler
                    }).toLong()
                    val url = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = AniyomiSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            val stub = SAnimeImpl().apply { this.url = url }
                            val episodes = src.getEpisodeList(stub)
                            AniyomiJson.episodesToJson(episodes)
                        }.fold(
                            onSuccess = { json -> withContext(Dispatchers.Main) { result.success(json) } },
                            onFailure = { err -> withContext(Dispatchers.Main) { result.error("EPISODES", "${err::class.java.simpleName}: ${err.message}", null) } },
                        )
                    }
                }

                "getVideoList" -> {
                    val sourceId = (call.argument<Number>("sourceId") ?: run {
                        result.error("BAD_ARGS", "sourceId required", null); return@setMethodCallHandler
                    }).toLong()
                    // Dart sends this under the key "url" (see AniyomiProvider.getVideoSources).
                    val episodeUrl = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = AniyomiSourceManager.get(sourceId) ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            val ep = SEpisodeImpl().apply {
                                this.url = episodeUrl
                                this.name = ""
                            }
                            // Legacy path first — covers sources like animeixin that override
                            // getVideoList(episode) / fetchVideoList. runCatching absorbs any
                            // IllegalStateException from sources that don't implement this path.
                            val legacyVideos = runCatching { src.getVideoList(ep) }.getOrElse { emptyList() }
                            val videos = if (legacyVideos.isNotEmpty()) {
                                legacyVideos
                            } else {
                                // Hoster path (lib-16): getHosterList → flatMap getVideoList(hoster).
                                // runCatching absorbs IllegalStateException from sources that
                                // don't implement this path either.
                                runCatching {
                                    val hosters = src.getHosterList(ep)
                                    hosters.flatMap { hoster ->
                                        runCatching { src.getVideoList(hoster) }.getOrElse { emptyList() }
                                    }
                                }.getOrElse { emptyList() }
                            }
                            // ONE clean entry per quality: the DIRECT url (mpv streams straight
                            // from the CDN with the video's headers — fast, native-like, exactly
                            // like Aniyomi), PLUS a hidden `proxyUrl`. The player uses the direct
                            // url first and only swaps to `proxyUrl` if a Cloudflare-walled stream
                            // won't start — no duplicate "· proxy" entries in the picker.
                            val arr = JSONArray()
                            videos.forEach { v ->
                                val rawUrl = v.videoUrl ?: v.url
                                val headersMap: Map<String, String> = buildMap {
                                    v.headers?.let { h ->
                                        for (i in 0 until h.size) put(h.name(i), h.value(i))
                                    }
                                }
                                val proxiedUrl = AniyomiVideoProxy.proxyUrl(sourceId, rawUrl, headersMap)
                                val json = AniyomiJson.videoToJson(v) // direct url + headers
                                json.put("proxyUrl", proxiedUrl)
                                arr.put(json)
                            }
                            arr.toString()
                        }.fold(
                            onSuccess = { json -> withContext(Dispatchers.Main) { result.success(json) } },
                            onFailure = { err -> withContext(Dispatchers.Main) { result.error("VIDEO_LIST", "${err::class.java.simpleName}: ${err.message}", null) } },
                        )
                    }
                }

                // Fetch image bytes through the source's own OkHttpClient so that
                // any CF session cookies / custom headers carried by that client are
                // used — Flutter's cached_network_image cannot pass Cloudflare.
                // Flutter receives a Uint8List; on failure result.error is called.
                "getImage" -> {
                    val sourceId = (call.argument<Number>("sourceId") ?: run {
                        result.error("BAD_ARGS", "sourceId required", null); return@setMethodCallHandler
                    }).toLong()
                    val url = call.argument<String>("url") ?: run {
                        result.error("BAD_ARGS", "url required", null); return@setMethodCallHandler
                    }
                    val src = AniyomiSourceManager.get(sourceId) as? AnimeHttpSource ?: run {
                        result.error("NO_SOURCE", "Source $sourceId not found or not an HTTP source", null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        runCatching {
                            val response = src.client.newCall(GET(url, src.headers)).execute()
                            val bytes = response.body?.bytes()
                                ?: throw IllegalStateException("empty body for $url")
                            bytes
                        }.fold(
                            onSuccess = { bytes ->
                                withContext(Dispatchers.Main) { result.success(bytes) }
                            },
                            onFailure = { err ->
                                withContext(Dispatchers.Main) {
                                    result.error("IMG_FETCH", "${err::class.java.simpleName}: ${err.message}", null)
                                }
                            },
                        )
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Serialises all registered sources as a JSON array string.
     *
     * Each element is a JSON object with:
     *   id      — [AnimeSource.id] (Long, serialised as a JSON number)
     *   name    — [AnimeSource.name]
     *   lang    — [AnimeSource.lang]
     *   nsfw    — from the owning [LoadedExtension.nsfw]
     *   pkg     — from the owning [LoadedExtension.pkg]
     *   baseUrl — [AnimeHttpSource.baseUrl] when the source is an HTTP source; "" otherwise
     */
    private fun sourcesJson(): String {
        val arr = JSONArray()
        AniyomiSourceManager.installed().forEach { ext ->
            ext.sources.forEach { src ->
                arr.put(
                    JSONObject().apply {
                        put("id", src.id)
                        put("name", src.name)
                        put("lang", src.lang)
                        put("nsfw", ext.nsfw)
                        put("pkg", ext.pkg)
                        put("baseUrl", (src as? AnimeHttpSource)?.baseUrl ?: "")
                        // Source-level headers (Referer/User-Agent) needed by the Dart layer
                        // to fetch thumbnail images without 403 errors on strict image hosts.
                        put(
                            "headers",
                            (src as? AnimeHttpSource)
                                ?.let { AniyomiJson.headersToJsonObject(it.headers) }
                                ?: JSONObject(),
                        )
                    },
                )
            }
        }
        return arr.toString()
    }
}
