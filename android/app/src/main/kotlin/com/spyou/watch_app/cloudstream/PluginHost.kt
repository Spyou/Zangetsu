package com.spyou.watch_app.cloudstream

import android.content.Context
import android.util.Log
import com.lagradost.cloudstream3.AnimeLoadResponse
import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.DubStatus
import com.lagradost.cloudstream3.Episode
import com.lagradost.cloudstream3.LiveStreamLoadResponse
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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

    // file id ("Name@version") -> the Plugin instance that registered it.
    // Kept so we can reach a source's plugin to invoke its openSettings (the
    // plugin's own settings UI). Only Plugin (not bare BasePlugin) instances.
    private val pluginsByFile =
        Collections.synchronizedMap(HashMap<String, Plugin>())

    // File ids whose plugin registered its MainAPI but threw during load() while
    // binding a settings UI against our (Application) context — e.g. plugins that
    // hard-cast the load context to an Activity (MovieBox). Their `openSettings`
    // is null right now, but re-loading against a real activity (freshOpener)
    // yields it, so we still advertise settings for them (show the gear) and bind
    // the sheet on demand when the user taps it.
    private val settingsDeferred =
        Collections.synchronizedSet(HashSet<String>())

    init {
        INSTANCE = this
        // Plugins reach for the global app context via CloudStreamApp; set it
        // before any plugin loads so requiresResources/settings plugins work.
        com.lagradost.cloudstream3.CloudStreamApp.setContext(context)

        // NiceHttp's shared client (com.lagradost.cloudstream3.app) ships with NO
        // cookie jar, so cookies never persist between requests. Give it a
        // CookieManager-backed jar: the WebView CF solver writes cf_clearance to
        // CookieManager, and this lets EVERY app.get() (incl. provider requests
        // made without the CloudflareKiller interceptor, e.g. AnimePahe's episode
        // fetch) send it. Additive + best-effort — never throws.
        applyBaseClient()
    }

    // The pristine NiceHttp client, captured ONCE before we touch it, so every
    // re-apply (cookie jar + CF interceptor + DoH) rebuilds from clean instead
    // of stacking interceptors again when the DNS choice changes.
    private val pristineClient by lazy { com.lagradost.cloudstream3.app.baseClient }

    private fun csPrefs() =
        context.getSharedPreferences("zangetsu_cs", Context.MODE_PRIVATE)

    /** Current opt-in DNS-over-HTTPS choice (see [Doh]); [Doh.OFF] by default. */
    fun dnsChoice(): Int = csPrefs().getInt("dns_choice", Doh.OFF)

    /** (Re)build the shared CS OkHttp client = cookie jar + CF interceptor + the
     *  selected DoH. Always rebuilds from [pristineClient] so it's idempotent.
     *  Additive + best-effort — never throws (OFF leaves DNS untouched). */
    private fun applyBaseClient() {
        runCatching {
            val app = com.lagradost.cloudstream3.app
            val b = pristineClient.newBuilder()
                .cookieJar(WebkitCookieJar())
                // cf_clearance is User-Agent-bound; this network interceptor
                // realigns the UA to the WebView solver's on requests that carry
                // the clearance cookie (incl. redirected hops).
                .addNetworkInterceptor(CfClearance.interceptor)
            app.baseClient = Doh.apply(b, dnsChoice()).build()
        }
    }

    /** Set the DoH provider (see [Doh]) and re-apply the client immediately. */
    fun setDns(choice: Int) {
        csPrefs().edit().putInt("dns_choice", choice).apply()
        applyBaseClient()
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
            // Run the plugin's own load(). Some plugins (e.g. MovieBox) hard-cast
            // the load context to an Activity to wire up their settings UI. We load
            // with the Application context (there's no activity at startup), so that
            // cast throws — but only AFTER the plugin has already registered its
            // MainAPI(s). Treat that as a SOFT success: the source itself works, and
            // its settings bind later against a real activity (see [openSettings] /
            // [freshOpener]). A throw BEFORE any API registers is still a hard fail
            // (e.g. TorraStream, which throws on class resolution before load).
            val fileId = file.nameWithoutExtension
            val loadError = runCatching {
                if (instance is Plugin) instance.load(context) else instance.load()
            }.exceptionOrNull()
            val registered = APIHolder.allProviders.any { it.sourcePlugin == fileId }
            if (loadError != null && !registered) throw loadError
            loaded.add(file.absolutePath)
            // Remember Plugin instances so we can surface/invoke their own
            // settings UI (openSettings, set during load()) later.
            if (instance is Plugin) {
                pluginsByFile[fileId] = instance
                // Threw while binding settings against the non-activity context →
                // remember it so the gear still shows; tapping it re-binds against a
                // real activity via freshOpener.
                if (loadError != null &&
                    loadError.message?.contains("Activity") == true
                ) {
                    settingsDeferred.add(fileId)
                }
            }
            if (loadError != null) {
                Log.w(
                    TAG,
                    "loadPlugin: $fileId registered but load() threw " +
                        "(${loadError.message}); settings deferred to activity bind",
                )
            }
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

    // Resolve a source from the key Dart sends. Three key shapes are handled:
    //   1. "<fileId>\u0001<name>" — the bundle-safe key. One `.cs3` can register
    //      MANY sources under ONE file id (e.g. CNC Verse → Netflix, Disney, …),
    //      so the file id alone is ambiguous; match BOTH to land on the exact
    //      source. Falls back to name-only, then file-id-only.
    //   2. bare "<fileId>" — a unique file id (disambiguated same-named forks).
    //   3. bare "<name>" — legacy callers; name match.
    private fun apiByName(key: String): MainAPI? {
        val sep = key.indexOf('\u0001')
        if (sep >= 0) {
            val sp = key.substring(0, sep)
            val nm = key.substring(sep + 1)
            return APIHolder.allProviders.firstOrNull {
                it.sourcePlugin == sp && it.name == nm
            }
                ?: APIHolder.allProviders.firstOrNull { it.name == nm }
                ?: APIHolder.allProviders.firstOrNull { it.sourcePlugin == sp }
        }
        return APIHolder.allProviders.firstOrNull { it.sourcePlugin == key }
            ?: APIHolder.allProviders.firstOrNull { it.name == key }
    }

    /** The plugin that registered the source [apiName], if it's one we track. */
    private fun pluginFor(apiName: String): Plugin? {
        val fileId = apiByName(apiName)?.sourcePlugin ?: return null
        return pluginsByFile[fileId]
    }

    /** True when [apiName]'s plugin exposes its own settings UI — either its
     *  `openSettings` is already bound, or the plugin registered but deferred its
     *  settings binding to an activity (see [loadPlugin] / [settingsDeferred]).
     *  Gated by a live registration, so a deleted source never advertises a gear. */
    fun hasSettings(apiName: String): Boolean {
        val fileId = apiByName(apiName)?.sourcePlugin ?: return false
        if (pluginsByFile[fileId]?.openSettings != null) return true
        return settingsDeferred.contains(fileId)
    }

    /** The plugin's settings opener for [apiName] — call with an AppCompatActivity
     * (plugins cast the Context to one). Null when the source has no settings. */
    fun settingsInvokerFor(apiName: String): ((android.content.Context) -> Unit)? =
        pluginFor(apiName)?.openSettings

    /**
     * Open [apiName]'s own settings UI against [activity].
     *
     * Some plugins (e.g. StremioX) capture `context as? AppCompatActivity` at
     * LOAD time and reuse it in openSettings. Real CloudStream loads plugins
     * from its AppCompatActivity, but we load them with the application context
     * (our host is a FlutterActivity), so that captured activity is null and the
     * sheet never shows. To fix it we re-instantiate the plugin with [activity]
     * as its load context — so its openSettings captures a real activity — then
     * immediately undo the duplicate MainAPI registration that re-loading causes
     * (we only want the freshly-bound openSettings). Falls back to the already
     * loaded plugin's opener for plugins that bind the activity at call time.
     *
     * @return true if an openSettings was invoked.
     */
    fun openSettings(apiName: String, activity: Context): Boolean {
        val fileId = apiByName(apiName)?.sourcePlugin ?: return false
        val path = synchronized(loaded) {
            loaded.firstOrNull { File(it).nameWithoutExtension == fileId }
        }
        if (path != null) {
            val opener = runCatching { freshOpener(File(path), fileId, activity) }
                .getOrNull()
            if (opener != null) {
                return runCatching { opener(activity); true }.getOrDefault(false)
            }
        }
        // Fallback: the already-loaded instance (works when it binds at call time).
        val opener = pluginsByFile[fileId]?.openSettings ?: return false
        return runCatching { opener(activity); true }.getOrDefault(false)
    }

    /** Re-instantiate the plugin in [file] with [activity] as its load context and
     *  return its freshly-bound openSettings, undoing the duplicate registration. */
    private fun freshOpener(
        file: File,
        fileId: String,
        activity: Context,
    ): ((Context) -> Unit)? {
        val loader = PathClassLoader(file.absolutePath, context.classLoader)
        val manifest = JSONObject(
            loader.getResourceAsStream("manifest.json")?.bufferedReader()
                ?.use { it.readText() } ?: return null,
        )
        val className = manifest.optString("pluginClassName")
        if (className.isEmpty()) return null
        val instance = loader.loadClass(className)
            .getDeclaredConstructor().newInstance() as? Plugin ?: return null
        instance.filename = fileId
        if (manifest.optBoolean("requiresResources")) {
            instance.resources = buildPluginResources(file)
        }
        val providers = APIHolder.allProviders
        val before = synchronized(providers) { providers.toList() }
        instance.load(activity) // binds openSettings against the real activity
        synchronized(providers) {
            providers.filter { it !in before }.forEach { dup ->
                providers.remove(dup)
                runCatching { APIHolder.removePluginMapping(dup) }
            }
        }
        return instance.openSettings
    }

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
        fileNames.forEach { pluginsByFile.remove(it) }
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
        synchronized(pluginsByFile) {
            pluginsByFile.keys.filter { internalNames.contains(internalOf(it)) }
                .forEach { pluginsByFile.remove(it) }
        }
        return removed
    }

    /** Unregister + delete ONE plugin's cached `.cs3`(s) for a SPECIFIC repo:
     *  its `<internalName>@<version>@<tag>` files, plus any legacy un-tagged
     *  `<internalName>@<version>` file (so a pre-namespacing shared cache is
     *  cleaned up on uninstall). Repo-scoped — removing one repo's "MovieBox"
     *  leaves a different repo's "MovieBox" (a different tag) untouched. */
    fun deleteByRepoPlugin(tag: String, internalName: String): Int {
        fun matches(fileId: String): Boolean {
            if (fileId.substringBefore('@') != internalName) return false
            // 1 '@' = legacy "name@version"; tagged is "name@version@tag".
            return fileId.count { it == '@' } == 1 || fileId.endsWith("@$tag")
        }
        var removed = 0
        val providers = APIHolder.allProviders
        synchronized(providers) {
            val gone = providers.filter { it.sourcePlugin != null && matches(it.sourcePlugin!!) }
            for (api in gone) {
                providers.remove(api)
                try { APIHolder.removePluginMapping(api) } catch (_: Exception) {}
                removed++
            }
        }
        val paths = loaded.filter { p -> matches(File(p).nameWithoutExtension) }
        for (p in paths) {
            try { File(p).delete() } catch (_: Exception) {}
            loaded.remove(p)
        }
        synchronized(pluginsByFile) {
            pluginsByFile.keys.filter { matches(it) }.toList().forEach { pluginsByFile.remove(it) }
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
                        }.onFailure {
                            android.util.Log.w(
                                "PluginHost",
                                "getMainPage '${mp.name}' failed for $apiName: $it",
                                it,
                            )
                        }.getOrNull()
                    }
                }
            }.awaitAll()
            // Zip each response back to the mainPage entry it came from so every
            // row can carry the category identifiers (name + data) needed to
            // re-fetch further pages. take(6) keeps them index-aligned.
            val cats = api.mainPage.take(6)
            for ((idx, resp) in responses.withIndex()) {
                if (resp == null) continue
                val mp = cats.getOrNull(idx)
                for (hpl in resp.items) {
                    val items = hpl.list.map { it.toMap(apiName) }
                    if (items.isNotEmpty()) {
                        // Existing keys ("title","items") are unchanged; the two
                        // "category*" keys are purely additive — an older Dart
                        // build just ignores them.
                        rows.add(
                            mapOf(
                                "title" to hpl.name,
                                "items" to items,
                                "categoryName" to (mp?.name ?: hpl.name),
                                "categoryData" to (mp?.data?.toString() ?: ""),
                            ),
                        )
                    }
                }
            }
        }
        return rows
    }

    /**
     * One further page of a single `mainPage` category, for the "See all"
     * browse grid's infinite scroll. Finds the mainPage entry matching [name]
     * (preferring an exact [data] match), re-runs [MainAPI.getMainPage] for
     * [page], and returns the item rows flattened across the response — mapped
     * with the same [toMap] as [getHome]. Guarded like [getHome]; any failure
     * (missing api/category, timeout, throw) degrades to an empty list.
     */
    fun getMainPagePaged(
        apiName: String,
        name: String,
        data: String,
        page: Int,
    ): List<Map<String, Any?>> {
        val api = apiByName(apiName) ?: return emptyList()
        if (!api.hasMainPage) return emptyList()
        // Prefer a category whose name AND data both match; fall back to a
        // name-only match so a source that reports empty/rewritten data still
        // paginates.
        val mp = api.mainPage.firstOrNull { it.name == name && it.data == data }
            ?: api.mainPage.firstOrNull { it.name == name }
            ?: return emptyList()
        val out = mutableListOf<Map<String, Any?>>()
        runBlocking {
            withTimeoutOrNull(HOME_ROW_TIMEOUT_MS) {
                runCatching {
                    api.getMainPage(page, MainPageRequest(mp.name, mp.data, true))
                }.onFailure {
                    android.util.Log.w(
                        "PluginHost",
                        "getMainPagePaged '$name' p$page failed for $apiName: $it",
                        it,
                    )
                }.getOrNull()
            }?.let { resp ->
                for (hpl in resp.items) {
                    out.addAll(hpl.list.map { it.toMap(apiName) })
                }
            }
        }
        return out
    }

    fun search(apiName: String, query: String): List<Map<String, Any?>> {
        val api = apiByName(apiName) ?: return emptyList()
        // Cap each search: with many installed sources, search fans out across
        // all of them on a shared pool — a dead/slow source must not hold a
        // worker thread (which would starve the others). Returns empty on timeout.
        //
        // Providers target different CloudStream search APIs and only override
        // ONE of them — calling the wrong overload hits MainAPI's default, which
        // throws NotImplementedError (that's why MovieBox/VegaMovies/HDHub4U/…
        // returned nothing). So try each form, newest-tolerant:
        //  1. legacy search(query): List<SearchResponse>        (older providers)
        //  2. paginated search(query, page): SearchResponseList (newer providers)
        //  3. quickSearch(query)                                (search-bar variant)
        // Mark a search in progress so the CF WebView solver stays SILENT for any
        // CF-gated source hit during the fan-out (no "verifying" popup in search).
        CfClearance.searchDepth.incrementAndGet()
        val res = try {
            runBlocking {
                withTimeoutOrNull(SEARCH_TIMEOUT_MS) {
                    runCatching { api.search(query) }.getOrNull()
                        ?: runCatching { api.search(query, 1)?.items }.getOrNull()
                        ?: runCatching { api.quickSearch(query) }.getOrNull()
                }
            }
        } finally {
            CfClearance.searchDepth.decrementAndGet()
        }
        return (res ?: emptyList()).map { it.toMap(apiName) }
    }

    /**
     * Search for the source-health probe / health-aware search. Unlike [search]
     * (which swallows everything to a list), this REPORTS the outcome so callers
     * can tell an honest empty result from a broken source:
     *
     *  - `{ items: [...] }`                  — responded (even with 0 hits)
     *  - `{ items: [], error: "timeout" }`   — exceeded [SEARCH_TIMEOUT_MS]
     *  - `{ items: [], error: "<msg>" }`     — every search overload threw
     *
     * The CF WebView solver is suppressed (via [CfClearance.searchDepth]) exactly
     * like [search], so a probe never pops a "verifying" overlay.
     */
    fun searchWithStatus(apiName: String, query: String): Map<String, Any?> {
        val api = apiByName(apiName)
            ?: return mapOf("items" to emptyList<Any?>(), "error" to "missing")
        CfClearance.searchDepth.incrementAndGet()
        var lastError: Throwable? = null
        val res = try {
            runBlocking {
                withTimeoutOrNull(SEARCH_TIMEOUT_MS) {
                    // Try each overload; remember the last failure so an
                    // all-failed run surfaces the real error, not just empty.
                    runCatching { api.search(query) }
                        .onFailure { lastError = it }.getOrNull()
                        ?: runCatching { api.search(query, 1)?.items }
                            .onFailure { lastError = it }.getOrNull()
                        ?: runCatching { api.quickSearch(query) }
                            .onFailure { lastError = it }.getOrNull()
                }
            }
        } finally {
            CfClearance.searchDepth.decrementAndGet()
        }
        return when {
            res != null -> mapOf("items" to res.map { it.toMap(apiName) })
            // withTimeoutOrNull returned null. If an overload actually threw we
            // surface that; otherwise the cap fired → timeout. (Note: when an
            // overload throws AND a later one returns empty-list, res is the
            // empty list and we report success — an honest empty.)
            lastError != null -> mapOf(
                "items" to emptyList<Any?>(),
                "error" to (lastError?.message ?: "error"),
            )
            else -> mapOf("items" to emptyList<Any?>(), "error" to "timeout")
        }
    }

    fun load(apiName: String, url: String, category: String = "sub"): Map<String, Any?>? {
        val api = apiByName(apiName) ?: return null
        val lr = runBlocking { runCatching { api.load(url) }.getOrNull() } ?: return null
        return lr.toDetailMap(apiName, category)
    }

    fun loadLinks(apiName: String, data: String, fast: Boolean = false): Map<String, Any?> {
        val empty = mapOf("sources" to emptyList<Any?>(), "subtitles" to emptyList<Any?>())
        val api = apiByName(apiName) ?: return empty
        // Synchronized: the provider emits links from a background coroutine while
        // the (fast) path reads them to return early.
        val links = Collections.synchronizedList(mutableListOf<ExtractorLink>())
        val subs = Collections.synchronizedList(mutableListOf<SubtitleFile>())
        runBlocking {
            val job = launch(Dispatchers.IO) {
                runCatching {
                    api.loadLinks(data, false, { sf -> subs.add(sf) }, { el -> links.add(el) })
                }.onFailure {
                    android.util.Log.w("PluginHost", "loadLinks failed for $apiName: $it", it)
                }
            }
            if (fast) {
                // Playback: return as soon as the first link(s) land (+ a short
                // grace to gather a couple of alternatives) instead of waiting for
                // EVERY mirror — that's the bulk of the "tap → playing" delay. The
                // download path keeps fast=false and still waits for all servers.
                withTimeoutOrNull(LOADLINKS_FAST_CAP_MS) {
                    while (links.isEmpty() && job.isActive) delay(50)
                    if (links.isNotEmpty()) delay(LOADLINKS_FAST_GRACE_MS)
                }
                job.cancel() // stop resolving the remaining (unneeded) mirrors
            } else {
                job.join() // wait for ALL servers (unchanged behavior)
            }
        }
        return mapOf(
            "sources" to links.toList().map { el ->
                // ClearKey-DRM sources (DrmExtractorLink — e.g. CNC/PlayzTV live
                // channels' CENC/DASH streams) carry a key id + key. mpv can't
                // decrypt DRM, so pass them through and let Dart route the source
                // to the native ExoPlayer player (which does clearkey natively).
                val drm = el as? com.lagradost.cloudstream3.utils.DrmExtractorLink
                mapOf(
                    "url" to el.url,
                    "name" to el.name,
                    "referer" to el.referer,
                    "quality" to el.quality,
                    "headers" to el.headers,
                    "isM3u8" to el.isM3u8,
                    "drmKid" to drm?.kid,
                    "drmKey" to drm?.key,
                )
            },
            "subtitles" to subs.toList().map { sf -> mapOf("lang" to sf.lang, "url" to sf.url) },
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

    private fun LoadResponse.toDetailMap(apiName: String, category: String = "sub"): Map<String, Any?> {
        // Anime sources key episodes by DubStatus (Subbed/Dubbed). Report both
        // counts so the app can offer a Sub/Dub toggle, and return the episode
        // list for the REQUESTED category (the toggle re-fetches with the other).
        var subCount = 0
        var dubCount = 0
        val episodes: List<Map<String, Any?>> = when (this) {
            is TvSeriesLoadResponse -> this.episodes.map { it.toMap() }
            is AnimeLoadResponse -> {
                val byStatus = this.episodes
                subCount = byStatus[DubStatus.Subbed]?.size ?: 0
                dubCount = byStatus[DubStatus.Dubbed]?.size ?: 0
                val wantDub = category.equals("dub", ignoreCase = true)
                val chosen = if (wantDub) {
                    byStatus[DubStatus.Dubbed] ?: byStatus[DubStatus.Subbed]
                } else {
                    byStatus[DubStatus.Subbed] ?: byStatus[DubStatus.Dubbed]
                } ?: byStatus.values.flatten() // sources keyed under None, etc.
                chosen.map { it.toMap() }
            }
            is MovieLoadResponse -> listOf(
                mapOf(
                    "data" to this.dataUrl, "name" to name,
                    "season" to 1, "episode" to 1, "posterUrl" to posterUrl,
                ),
            )
            // Live TV (PlayzTV etc.) — a LiveStreamLoadResponse is a single
            // live HLS behind dataUrl, structurally identical to a movie, so
            // surface it as one playable item down the same loadLinks path.
            is LiveStreamLoadResponse -> listOf(
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
            "subCount" to subCount,
            "dubCount" to dubCount,
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

        /** The live host, so the settings Activity (a separate AppCompatActivity)
         * can reach the plugin registry to invoke a source's openSettings. */
        @Volatile
        var INSTANCE: PluginHost? = null
            private set

        /** Per-row deadline for [getHome] so one slow category can't stall it. */
        private const val HOME_ROW_TIMEOUT_MS = 8000L

        /** Per-source deadline for [search] so a dead source can't hold a worker. */
        private const val SEARCH_TIMEOUT_MS = 10000L

        /** Fast (playback) loadLinks: grace window after the first link to gather a
         * few alternatives before returning, and a hard cap if no link arrives. */
        private const val LOADLINKS_FAST_GRACE_MS = 700L
        private const val LOADLINKS_FAST_CAP_MS = 15000L
    }
}
