package com.spyou.watch_app.cloudstream

import android.content.Context
import android.util.Log
import com.lagradost.cloudstream3.AnimeLoadResponse
import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.Episode
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MainPageRequest
import com.lagradost.cloudstream3.MovieLoadResponse
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.TvSeriesLoadResponse
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.utils.ExtractorLink
import dalvik.system.PathClassLoader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Collections
import org.json.JSONObject
import java.io.File

/**
 * Loads `.cs3` plugins via [PathClassLoader] against the bundled CloudStream
 * library and exposes their `MainAPI`s (search / load / loadLinks) as plain
 * JSON-able maps for the Flutter bridge. Every plugin load and every call is
 * isolated in try/catch — a bad plugin must never crash the host app.
 *
 * Registered APIs land in [APIHolder.allProviders] (CloudStream's global
 * registry, where `BasePlugin.registerMainAPI` adds them); we look them up by
 * `name`.
 */
class PluginHost(private val context: Context) {

    // Absolute paths already loaded. Thread-safe: installs run on csExecutor
    // while read ops run on csReadPool, so both may touch this concurrently.
    private val loaded = Collections.synchronizedSet(HashSet<String>())

    init {
        // Plugins reach for the global app context via CloudStreamApp; set it
        // before any plugin loads so requiresResources/settings plugins work.
        com.lagradost.cloudstream3.CloudStreamApp.setContext(context)
    }

    /** PathClassLoader → manifest.json → instantiate → load(). Returns success. */
    fun loadPlugin(file: File): Boolean {
        if (loaded.contains(file.absolutePath)) return true
        return try {
            // Android 8+ refuses to load a dex/.cs3 the app can WRITE to (W^X
            // security). Mark it read-only first — exactly what CloudStream does.
            if (file.canWrite()) file.setReadOnly()
            val loader = PathClassLoader(file.absolutePath, context.classLoader)
            val manifestText = loader.getResourceAsStream("manifest.json")
                ?.bufferedReader()?.use { it.readText() }
                ?: return false
            val manifest = JSONObject(manifestText)
            val className = manifest.optString("pluginClassName")
            if (className.isEmpty()) return false
            val instance = loader.loadClass(className)
                .getDeclaredConstructor().newInstance() as BasePlugin
            // Stamp the plugin file id so every MainAPI it registers carries
            // `sourcePlugin` = this file's name (registerMainAPI copies it).
            // That's how we attribute a source back to its repo + delete it.
            instance.filename = file.nameWithoutExtension
            // Plugins with their own settings UI bundle Android resources and
            // declare requiresResources; build a Resources backed by the .cs3
            // (it's an APK with resources.arsc + res/) and hand it to the plugin
            // BEFORE load(), exactly like CloudStream — otherwise these plugins
            // throw on load and never install (e.g. AnimePahe).
            if (instance is Plugin && manifest.optBoolean("requiresResources")) {
                instance.resources = buildPluginResources(file)
            }
            if (instance is Plugin) instance.load(context) else instance.load()
            loaded.add(file.absolutePath)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "loadPlugin failed for ${file.name}: ${t.message}")
            false
        }
    }

    /** Build a [Resources] backed by the plugin's `.cs3` (an APK carrying
     * resources.arsc + res/). Mirrors CloudStream's PluginManager so plugins
     * that declare `requiresResources` can inflate their own settings UI. */
    private fun buildPluginResources(file: File): android.content.res.Resources {
        val assets = android.content.res.AssetManager::class.java
            .getDeclaredConstructor().newInstance()
        android.content.res.AssetManager::class.java
            .getMethod("addAssetPath", String::class.java)
            .invoke(assets, file.absolutePath)
        return android.content.res.Resources(
            assets,
            context.resources.displayMetrics,
            context.resources.configuration,
        )
    }

    fun loadAll(files: List<File>): Int = files.count { loadPlugin(it) }

    private fun apiByName(name: String): MainAPI? =
        APIHolder.allProviders.firstOrNull { it.name == name }

    /** Every currently-registered source. `sourcePlugin` = the .cs3 file id that
     * registered it, used by Dart to group sources under their repo. */
    fun installedApis(): List<Map<String, Any?>> =
        APIHolder.allProviders.map { api ->
            mapOf(
                "name" to api.name,
                "lang" to api.lang,
                "hasMainPage" to api.hasMainPage,
                "types" to api.supportedTypes.map { it.name },
                "sourcePlugin" to api.sourcePlugin,
            )
        }

    /** The file ids ("internalName@version") of every currently-loaded plugin. */
    fun installedFileIds(): Set<String> =
        APIHolder.allProviders.mapNotNull { it.sourcePlugin }.toSet()

    /** Unregister + delete the cached `.cs3`s for a repo (by their file ids,
     * e.g. "VegaMovies@80"). Returns how many MainAPIs were removed. */
    fun deleteByFiles(fileNames: Set<String>): Int {
        var removed = 0
        val providers = APIHolder.allProviders
        synchronized(providers) {
            val gone = providers.filter { it.sourcePlugin != null && fileNames.contains(it.sourcePlugin) }
            for (api in gone) {
                providers.remove(api)
                try { APIHolder.removePluginMapping(api) } catch (_: Exception) {}
                removed++
            }
        }
        // Delete the cached files + forget them so they don't reload next launch.
        val paths = loaded.filter { p -> fileNames.contains(File(p).nameWithoutExtension) }
        for (p in paths) {
            try { File(p).delete() } catch (_: Exception) {}
            loaded.remove(p)
        }
        return removed
    }

    /** Like [deleteByFiles] but matches by the part before '@' (the plugin's
     * internalName), so it clears ALL cached versions of a plugin — used by the
     * update flow to drop the old version before downloading the new one. */
    fun deleteByInternalNames(internalNames: Set<String>): Int {
        fun internalOf(fileId: String) = fileId.substringBefore('@')
        var removed = 0
        val providers = APIHolder.allProviders
        synchronized(providers) {
            val gone = providers.filter {
                it.sourcePlugin != null && internalNames.contains(internalOf(it.sourcePlugin!!))
            }
            for (api in gone) {
                providers.remove(api)
                try { APIHolder.removePluginMapping(api) } catch (_: Exception) {}
                removed++
            }
        }
        val paths = loaded.filter { p ->
            internalNames.contains(internalOf(File(p).nameWithoutExtension))
        }
        for (p in paths) {
            try { File(p).delete() } catch (_: Exception) {}
            loaded.remove(p)
        }
        return removed
    }

    /** The source's home rows (its `mainPage` categories), capped for latency. */
    fun getHome(apiName: String): List<Map<String, Any?>> {
        val api = apiByName(apiName) ?: return emptyList()
        if (!api.hasMainPage) return emptyList()
        val rows = mutableListOf<Map<String, Any?>>()
        runBlocking {
            // Fetch the home rows CONCURRENTLY (each getMainPage is a network
            // call) instead of sequentially, with a per-row deadline so one
            // stuck/dead category can't hold up the whole home — awaitAll waits
            // for the slowest row.
            val responses = api.mainPage.take(6).map { mp ->
                async(Dispatchers.IO) {
                    withTimeoutOrNull(HOME_ROW_TIMEOUT_MS) {
                        runCatching {
                            api.getMainPage(1, MainPageRequest(mp.name, mp.data, false))
                        }.getOrNull()
                    }
                }
            }.awaitAll()
            for (resp in responses) {
                if (resp == null) continue
                for (hpl in resp.items) {
                    val items = hpl.list.map { it.toMap(apiName) }
                    if (items.isNotEmpty()) {
                        rows.add(mapOf("title" to hpl.name, "items" to items))
                    }
                }
            }
        }
        return rows
    }

    fun search(apiName: String, query: String): List<Map<String, Any?>> {
        val api = apiByName(apiName) ?: return emptyList()
        // Cap each search: with many installed sources, search fans out across
        // all of them on a shared pool — a dead/slow source must not hold a
        // worker thread (which would starve the others). Returns empty on timeout.
        val res = runBlocking {
            withTimeoutOrNull(SEARCH_TIMEOUT_MS) {
                runCatching { api.search(query) }.getOrNull()
            }
        } ?: return emptyList()
        return res.map { it.toMap(apiName) }
    }

    fun load(apiName: String, url: String): Map<String, Any?>? {
        val api = apiByName(apiName) ?: return null
        val lr = runBlocking { runCatching { api.load(url) }.getOrNull() } ?: return null
        return lr.toDetailMap(apiName)
    }

    fun loadLinks(apiName: String, data: String): Map<String, Any?> {
        val empty = mapOf("sources" to emptyList<Any?>(), "subtitles" to emptyList<Any?>())
        val api = apiByName(apiName) ?: return empty
        val links = mutableListOf<ExtractorLink>()
        val subs = mutableListOf<SubtitleFile>()
        runBlocking {
            runCatching {
                api.loadLinks(data, false, { sf -> subs.add(sf) }, { el -> links.add(el) })
            }
        }
        return mapOf(
            "sources" to links.map { el ->
                mapOf(
                    "url" to el.url,
                    "name" to el.name,
                    "referer" to el.referer,
                    "quality" to el.quality,
                    "headers" to el.headers,
                    "isM3u8" to el.isM3u8,
                )
            },
            "subtitles" to subs.map { sf -> mapOf("lang" to sf.lang, "url" to sf.url) },
        )
    }

    // ── mappers ──────────────────────────────────────────────────────────────

    private fun SearchResponse.toMap(apiName: String): Map<String, Any?> = mapOf(
        "name" to name,
        "url" to url,
        "posterUrl" to posterUrl,
        "posterHeaders" to posterHeaders,
        "type" to type?.name,
        "apiName" to apiName,
    )

    private fun LoadResponse.toDetailMap(apiName: String): Map<String, Any?> {
        val episodes: List<Map<String, Any?>> = when (this) {
            is TvSeriesLoadResponse -> this.episodes.map { it.toMap() }
            is AnimeLoadResponse -> this.episodes.values.flatten().map { it.toMap() }
            is MovieLoadResponse -> listOf(
                mapOf(
                    "data" to this.dataUrl, "name" to name,
                    "season" to 1, "episode" to 1, "posterUrl" to posterUrl,
                ),
            )
            else -> emptyList()
        }
        // Ids the provider exposed (mal/anilist/imdb/tmdb/simkl) — used app-side
        // for tracker sync + Cast/Relations enrichment. Plus the provider's own
        // cast (actors) and related titles (recommendations), so those tabs work
        // even when the provider sets no ids. All best-effort.
        val sync = runCatching { this.syncData }.getOrNull() ?: emptyMap<String, String>()
        val actors = runCatching {
            this.actors?.map { ad ->
                mapOf(
                    "name" to ad.actor.name,
                    "image" to ad.actor.image,
                    "role" to (ad.roleString ?: ad.role?.name),
                )
            }
        }.getOrNull() ?: emptyList<Map<String, Any?>>()
        val recommendations = runCatching {
            this.recommendations?.map { it.toMap(apiName) }
        }.getOrNull() ?: emptyList<Map<String, Any?>>()
        return mapOf(
            "name" to name,
            "url" to url,
            "posterUrl" to posterUrl,
            "plot" to plot,
            "year" to year,
            "type" to type?.name,
            "apiName" to apiName,
            "episodes" to episodes,
            "syncData" to sync,
            "actors" to actors,
            "recommendations" to recommendations,
        )
    }

    private fun Episode.toMap(): Map<String, Any?> = mapOf(
        "data" to data,
        "name" to name,
        "season" to season,
        "episode" to episode,
        "posterUrl" to posterUrl,
    )

    companion object {
        const val TAG = "CloudStream"

        /** Per-row deadline for [getHome] so one slow category can't stall it. */
        private const val HOME_ROW_TIMEOUT_MS = 8000L

        /** Per-source deadline for [search] so a dead source can't hold a worker. */
        private const val SEARCH_TIMEOUT_MS = 10000L
    }
}
