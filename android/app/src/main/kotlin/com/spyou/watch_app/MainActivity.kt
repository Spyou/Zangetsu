package com.spyou.watch_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Log
import android.util.Rational
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.spyou.watch_app.aniyomi.AniyomiBridge
import com.spyou.watch_app.cloudstream.PluginHost
import com.spyou.watch_app.cloudstream.RepoManager
import com.spyou.watch_app.cloudstream.SubscriptionWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import io.flutter.embedding.android.FlutterActivity
import java.util.concurrent.TimeUnit
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/// Hosts the "zangetsu/seek_preview" channel, which decodes a single video
/// frame at a given timestamp via [MediaMetadataRetriever] — the same technique
/// native players (CloudStream etc.) use for seek-bar thumbnails. No second
/// player, no video surface: just URL + time -> JPEG bytes.
class MainActivity : FlutterActivity() {
    private val channelName = "zangetsu/seek_preview"
    private val executor = Executors.newSingleThreadExecutor()

    // CloudStream bridge. Mutating ops (install/load/delete repos) run on a
    // single thread [csExecutor] so plugin (un)registration stays serialized
    // and race-free. Read ops (getHome/search/load/loadLinks) run on a small
    // pool [csReadPool] so a slow or stale source request can't block the
    // active source's load — switching sources stays responsive.
    private val csExecutor = Executors.newSingleThreadExecutor()
    // Sized for search fan-out: a query hits every installed source at once, so
    // a few extra workers let results come back without one slow source choking
    // the rest (each call is also time-capped in PluginHost).
    private val csReadPool = Executors.newFixedThreadPool(8)
    private val repo: RepoManager by lazy { RepoManager(applicationContext) }
    private val host: PluginHost by lazy { PluginHost(applicationContext) }

    companion object {
        private const val TAG = "SeekPreview"
        private const val EXT_PLAYER_REQUEST = 7001

        /** The foreground activity, so the CloudStream CloudflareKiller can
         * attach its solver WebView to a real window (JS only runs when the
         * WebView renders). Weak ref; null while backgrounded. */
        @Volatile
        var current: java.lang.ref.WeakReference<android.app.Activity>? = null
    }

    override fun onResume() {
        super.onResume()
        current = java.lang.ref.WeakReference(this)
    }

    override fun onPause() {
        if (current?.get() === this) current = null
        super.onPause()
    }

    // A "new episode" notification tapped while the app is already running:
    // forward its payload to Dart so it opens that show's Detail.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("notif_payload")?.let { payload ->
            notifChannel?.invokeMethod("openShow", payload)
            intent.removeExtra("notif_payload")
        }
    }

    // The in-flight external-player launch, completed in onActivityResult so the
    // Dart side learns whether the player actually played anything (for the
    // auto-fallback to the built-in player).
    private var pendingPlayerResult: MethodChannel.Result? = null

    // Cached retriever so rapid scrubbing on one title doesn't re-open the
    // source for every frame (setDataSource is expensive, esp. over network).
    private var retriever: MediaMetadataRetriever? = null
    private var currentUrl: String? = null

    // Auto Picture-in-Picture: armed by Dart while a video is on screen. On
    // Android 12+ we use the seamless setAutoEnterEnabled; on 8.0–11 (no
    // auto-enter API) we trigger PiP from onUserLeaveHint (home press).
    private var autoPipEnabled = false
    private val pipAspect = Rational(16, 9)

    // Set in configureFlutterEngine; used by onNewIntent to hand a tapped
    // "new episode" notification to Dart while the app is already running.
    private var notifChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // TV ExoPlayer spike (SP0) — register the SurfaceView PlatformView.
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "zangetsu/exoplayer_view",
            ExoPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "frame" -> {
                        val url = call.argument<String>("url")
                        val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                        val headers = call.argument<Map<String, String>>("headers")
                        val maxWidth = (call.argument<Number>("maxWidth") ?: 320).toInt()
                        if (url == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        executor.execute {
                            val bytes = extractFrame(url, positionMs, headers, maxWidth)
                            runOnUiThread { result.success(bytes) }
                        }
                    }
                    "release" -> {
                        executor.execute {
                            releaseRetriever()
                            runOnUiThread { result.success(null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // External-player channel: list installed players + hand a stream off to
        // one via ACTION_VIEW (URL + headers + subtitles + title).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zangetsu/external_player")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPlayers" -> result.success(installedPlayers())
                    "launch" -> launchExternal(call, result)
                    "proxyUrl" -> {
                        try {
                            val url = call.argument<String>("url")
                            @Suppress("UNCHECKED_CAST")
                            val headers = (call.argument<Map<String, String>>("headers"))
                                ?: emptyMap()
                            if (url.isNullOrEmpty()) {
                                result.success(null)
                            } else {
                                result.success(ExternalStreamProxy.proxyUrl(url, headers))
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("ext-player", "proxyUrl failed: ${e.message}")
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Notifications channel: deliver the "new episode" notification a CS
        // worker posted (its launch intent carries notif_payload) to Dart so it
        // can open that show's Detail. getInitialNotification covers cold/back
        // launch; onNewIntent (below) covers a tap while the app is running.
        notifChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zangetsu/notifications",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialNotification" -> {
                        val payload = intent?.getStringExtra("notif_payload")
                        intent?.removeExtra("notif_payload") // consume once
                        result.success(payload)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // PiP channel: Dart arms/disarms auto-PiP while the player is on screen.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zangetsu/pip")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAutoPip" -> {
                        autoPipEnabled = (call.arguments as? Boolean) ?: false
                        // Android 12+: seamless auto-enter (survives gesture nav).
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            try {
                                setPictureInPictureParams(
                                    PictureInPictureParams.Builder()
                                        .setAutoEnterEnabled(autoPipEnabled)
                                        .setAspectRatio(pipAspect)
                                        .build(),
                                )
                            } catch (_: Exception) {}
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // Torrent channel: native libtorrent4j streaming engine (Phase 1).
        // Inert until Dart calls startStream — only wires the channels here.
        TorrentEngine(applicationContext, flutterEngine.dartExecutor.binaryMessenger)

        // Torrent DOWNLOAD engine (Phase 2) — separate persistent session +
        // channels; inert until Dart calls enqueue.
        TorrentDownloadEngine(applicationContext, flutterEngine.dartExecutor.binaryMessenger)

        // CloudStream channel: install repos and drive `.cs3` plugins' search /
        // load / loadLinks. All handlers run on [csExecutor] (network + plugin
        // work is blocking) and post back via runOnUiThread; any failure is
        // surfaced to Dart as a "cs_error".
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zangetsu/cloudstream")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Solve Cloudflare for [url] in the WebView solver and hand back
                    // the clearance cookie + matching User-Agent, so the JS-provider
                    // fetch layer (Dart) can attach them to its own requests. Runs
                    // off the main thread (solve() blocks on a WebView latch).
                    "solveCloudflare" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url required", null)
                            return@setMethodCallHandler
                        }
                        csExecutor.execute {
                            val solved = try {
                                com.lagradost.cloudstream3.network.CfWebViewSolver.solve(url)
                            } catch (e: Exception) {
                                null
                            }
                            runOnUiThread {
                                if (solved != null) {
                                    result.success(
                                        mapOf(
                                            "cookie" to solved.cookie,
                                            "userAgent" to solved.userAgent,
                                        ),
                                    )
                                } else {
                                    result.success(null)
                                }
                            }
                        }
                    }
                    // Add (or refresh) a repo: fetch its catalog only — does NOT
                    // download/install anything. The user installs plugins one by
                    // one via "installPlugin". Returns the repo name + its full
                    // advertised plugin list (the catalog).
                    "addRepo" -> {
                        val url = call.argument<String>("url")
                        csExecutor.execute {
                            try {
                                val (repoName, plugins) = repo.loadRepo(url ?: "")
                                val info = mapOf(
                                    "name" to repoName,
                                    "url" to (url ?: ""),
                                    "plugins" to plugins.map { it.toMap() },
                                )
                                runOnUiThread { result.success(info) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // Install ONE plugin (download its .cs3 + load it). Returns the
                    // updated installed-source list so Dart can rebuild.
                    "installPlugin" -> {
                        val cs3Url = call.argument<String>("url")
                        val internalName = call.argument<String>("internalName")
                        val version = call.argument<Int>("version") ?: 1
                        val repoUrl = call.argument<String>("repoUrl") ?: ""
                        csExecutor.execute {
                            try {
                                val file = repo.download(
                                    cs3Url ?: "",
                                    internalName ?: "",
                                    version,
                                    repoUrl,
                                )
                                // Surface a genuine load failure instead of a
                                // false "installed": some sources need a newer
                                // CloudStream API than this build provides.
                                if (host.loadPlugin(file)) {
                                    runOnUiThread { result.success(host.installedApis()) }
                                } else {
                                    runOnUiThread {
                                        result.error(
                                            "cs_load_failed",
                                            "Couldn't load this source — it may need a newer app version.",
                                            null,
                                        )
                                    }
                                }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // Uninstall ONE plugin, repo-scoped by repoUrl (so two repos'
                    // same-named plugins uninstall independently). Falls back to
                    // the legacy by-internalName delete when no repoUrl is known.
                    "uninstallPlugin" -> {
                        val internalName = call.argument<String>("internalName") ?: ""
                        val repoUrl = call.argument<String>("repoUrl") ?: ""
                        csExecutor.execute {
                            try {
                                if (repoUrl.isNotEmpty()) {
                                    host.deleteByRepoPlugin(
                                        com.spyou.watch_app.cloudstream.RepoManager.repoTag(repoUrl),
                                        internalName,
                                    )
                                } else {
                                    host.deleteByInternalNames(setOf(internalName))
                                }
                                runOnUiThread { result.success(host.installedApis()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "listSources" -> {
                        csExecutor.execute {
                            try {
                                host.loadAll(repo.cachedFiles())
                                val apis = host.installedApis()
                                runOnUiThread { result.success(apis) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // In-app DNS-over-HTTPS for CS sources (opt-in; 0 = Off).
                    "getDns" -> result.success(host.dnsChoice())
                    "setDns" -> {
                        val choice = call.argument<Int>("choice") ?: 0
                        csExecutor.execute {
                            runCatching { host.setDns(choice) }
                            runOnUiThread { result.success(true) }
                        }
                    }
                    // Mirror CS subscriptions to native + (re)schedule the periodic
                    // background "new episode" worker. Merges so the worker's
                    // advanced episode counts survive a re-sync from Dart.
                    "syncSubscriptions" -> {
                        @Suppress("UNCHECKED_CAST")
                        val incoming =
                            (call.argument<List<Map<String, Any?>>>("subs") ?: emptyList())
                        csExecutor.execute {
                            runCatching { mergeSubscriptions(incoming) }
                            runOnUiThread { result.success(true) }
                        }
                    }
                    // Run the CS subscription check once, now (e.g. "Check now").
                    "checkSubscriptionsNow" -> {
                        runCatching {
                            WorkManager.getInstance(applicationContext).enqueue(
                                OneTimeWorkRequestBuilder<SubscriptionWorker>()
                                    .setConstraints(
                                        Constraints.Builder()
                                            .setRequiredNetworkType(NetworkType.CONNECTED)
                                            .build(),
                                    )
                                    .build(),
                            )
                        }
                        result.success(true)
                    }
                    "deleteRepo" -> {
                        @Suppress("UNCHECKED_CAST")
                        val files = (call.argument<List<String>>("files") ?: emptyList())
                        csExecutor.execute {
                            try {
                                host.deleteByFiles(files.toSet())
                                val apis = host.installedApis()
                                runOnUiThread { result.success(apis) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // Check a repo for updates: re-fetch its catalog and re-install
                    // ONLY the plugins that are currently installed whose version
                    // changed (never auto-installs new ones). Returns fresh catalog
                    // + the updated source list.
                    "updateRepo" -> {
                        val url = call.argument<String>("url")
                        csExecutor.execute {
                            try {
                                val (repoName, plugins) = repo.loadRepo(url ?: "")
                                val installed = host.installedFileIds() // "name@ver[@tag]"
                                // Tag is per-REPO (the repo url the user added), so
                                // updating one repo never touches another repo's
                                // same-named plugin.
                                val tag = com.spyou.watch_app.cloudstream.RepoManager
                                    .repoTag(url ?: "")
                                var updated = 0 // plugins actually re-downloaded
                                for (plugin in plugins) {
                                    // Only update THIS repo's copy: its tagged file
                                    // or a legacy un-tagged one (1 '@').
                                    val mine = installed.any {
                                        it.substringBefore('@') == plugin.internalName &&
                                            (it.endsWith("@$tag") || it.count { c -> c == '@' } == 1)
                                    }
                                    if (!mine) continue
                                    val newId = "${plugin.internalName}@${plugin.version}@$tag"
                                    if (installed.contains(newId)) continue // already current
                                    try {
                                        host.deleteByRepoPlugin(tag, plugin.internalName)
                                        host.loadPlugin(repo.download(plugin))
                                        updated++
                                    } catch (_: Exception) { /* skip a bad plugin */ }
                                }
                                val info = mapOf(
                                    "name" to repoName,
                                    "url" to (url ?: ""),
                                    "plugins" to plugins.map { it.toMap() },
                                    "sources" to host.installedApis(),
                                    "updated" to updated,
                                )
                                runOnUiThread { result.success(info) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // READ-ONLY update check: re-fetch a repo's catalog and report
                    // which currently-installed plugins have a newer version online,
                    // WITHOUT downloading anything. Never mutates plugins/disk/state,
                    // so it can't affect playback or installed sources. Returns
                    // { url, outdated:[{internalName,name,url,installedVersion,onlineVersion}] }.
                    "checkRepoUpdates" -> {
                        val url = call.argument<String>("url")
                        csReadPool.execute {
                            try {
                                val (_, plugins) = repo.loadRepo(url ?: "")
                                val installed = host.installedFileIds() // "name@ver[@tag]"
                                val tag = com.spyou.watch_app.cloudstream.RepoManager
                                    .repoTag(url ?: "")
                                val outdated = mutableListOf<Map<String, Any?>>()
                                for (plugin in plugins) {
                                    // THIS repo's installed copy (tagged or legacy).
                                    // Use the HIGHEST installed version: an older `.cs3`
                                    // left on disk (stale/mismatched tag from a past
                                    // update) must NOT make a current plugin look
                                    // outdated. With firstOrNull the leftover old file
                                    // could win → a false, sticky "update available".
                                    val installedVersion = installed
                                        .filter {
                                            it.substringBefore('@') == plugin.internalName &&
                                                (it.endsWith("@$tag") || it.count { c -> c == '@' } == 1)
                                        }
                                        .mapNotNull { it.split('@').getOrNull(1)?.toIntOrNull() }
                                        .maxOrNull() ?: continue
                                    if (plugin.version > installedVersion) {
                                        outdated.add(
                                            mapOf(
                                                "internalName" to plugin.internalName,
                                                "name" to plugin.name,
                                                "url" to plugin.url,
                                                "installedVersion" to installedVersion,
                                                "onlineVersion" to plugin.version,
                                            ),
                                        )
                                    }
                                }
                                val info = mapOf("url" to (url ?: ""), "outdated" to outdated)
                                runOnUiThread { result.success(info) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // Update ONE installed plugin to a specific version: drop its old
                    // cached `.cs3` (repo-scoped) and download + load the new one.
                    // Mirrors updateRepo's inner loop for a single plugin. Returns the
                    // refreshed source list.
                    "updatePlugin" -> {
                        val cs3Url = call.argument<String>("url") ?: ""
                        val internalName = call.argument<String>("internalName") ?: ""
                        val version = call.argument<Int>("version") ?: 1
                        val repoUrl = call.argument<String>("repoUrl") ?: ""
                        csExecutor.execute {
                            try {
                                val tag = com.spyou.watch_app.cloudstream.RepoManager
                                    .repoTag(repoUrl)
                                host.deleteByRepoPlugin(tag, internalName)
                                host.loadPlugin(
                                    repo.download(cs3Url, internalName, version, repoUrl),
                                )
                                val apis = host.installedApis()
                                runOnUiThread { result.success(apis) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "getHome" -> {
                        val name = call.argument<String>("name")
                        csReadPool.execute {
                            try {
                                val res = host.getHome(name ?: "")
                                // Serialize on THIS background thread, not the UI
                                // thread. Handing Flutter a big nested List<Map>
                                // makes the platform-channel codec encode it on the
                                // main thread, which skips frames on large feeds
                                // (e.g. MovieBox). A single JSON string encodes
                                // cheaply on the main thread; Dart decodes it off
                                // the UI thread.
                                val json = org.json.JSONArray(res).toString()
                                runOnUiThread { result.success(json) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // One further page of a single mainPage category, for the
                    // "See all" browse grid's infinite scroll. Additive — returns
                    // a flat list of item maps (decoded like `search`).
                    "getMainPagePaged" -> {
                        val name = call.argument<String>("name")
                        val data = call.argument<String>("data")
                        val page = call.argument<Int>("page") ?: 1
                        val apiName = call.argument<String>("apiName")
                        csReadPool.execute {
                            try {
                                val res = host.getMainPagePaged(
                                    apiName ?: "",
                                    name ?: "",
                                    data ?: "",
                                    page,
                                )
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "search" -> {
                        val name = call.argument<String>("name")
                        val query = call.argument<String>("query")
                        csReadPool.execute {
                            try {
                                val res = host.search(name ?: "", query ?: "")
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // Status-reporting search for the source-health feature:
                    // returns {items, error?} so callers can tell an honest empty
                    // result from a timed-out / broken source (plain `search`
                    // collapses both to []).
                    "searchStatus" -> {
                        val name = call.argument<String>("name")
                        val query = call.argument<String>("query")
                        csReadPool.execute {
                            try {
                                val res = host.searchWithStatus(name ?: "", query ?: "")
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "load" -> {
                        val name = call.argument<String>("name")
                        val url = call.argument<String>("url")
                        val category = call.argument<String>("category") ?: "sub"
                        csReadPool.execute {
                            try {
                                val res = host.load(name ?: "", url ?: "", category)
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "loadLinks" -> {
                        val name = call.argument<String>("name")
                        val data = call.argument<String>("data")
                        val fast = call.argument<Boolean>("fast") ?: false
                        csReadPool.execute {
                            try {
                                val res = host.loadLinks(name ?: "", data ?: "", fast)
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    // Does this source's plugin expose its own settings UI?
                    "hasPluginSettings" -> {
                        val name = call.argument<String>("name")
                        try {
                            result.success(host.hasSettings(name ?: ""))
                        } catch (e: Exception) {
                            result.error("cs_error", e.message, null)
                        }
                    }
                    // Open the plugin's own settings UI in a dedicated
                    // AppCompatActivity (plugins cast the Context to one).
                    "openPluginSettings" -> {
                        val name = call.argument<String>("name")
                        runOnUiThread {
                            try {
                                val intent = android.content.Intent(
                                    this,
                                    com.spyou.watch_app.cloudstream.CloudStreamSettingsActivity::class.java,
                                ).putExtra(
                                    com.spyou.watch_app.cloudstream.CloudStreamSettingsActivity.EXTRA_API_NAME,
                                    name,
                                )
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("cs_error", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Aniyomi channel: load Aniyomi anime-extension APKs, register sources,
        // and expose them to the Flutter layer for browse/search/play. Mirrors the
        // CloudStream channel registration style above.
        val aniyomiChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zangetsu/aniyomi")
        AniyomiBridge(applicationContext, CoroutineScope(Dispatchers.IO)).attach(aniyomiChannel)

        // Device-class detection: lets Dart know if the app is running on an
        // Android TV / Leanback device. Returns false on phones/tablets so every
        // TV layout branch is a no-op on the phone build.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.spyou.watch_app/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTv" -> {
                        val uiModeManager = getSystemService(android.content.Context.UI_MODE_SERVICE) as android.app.UiModeManager
                        val isTv = uiModeManager.currentModeType == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION ||
                            packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK) ||
                            packageManager.hasSystemFeature("android.software.leanback_only")
                        result.success(isTv)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Android 8.0–11 have no auto-enter API, so enter PiP here when the user
    // leaves via Home/Recents while a video is armed. Android 12+ is handled by
    // setAutoEnterEnabled above, so we skip it here to avoid a double trigger.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPipEnabled &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            !isInPictureInPictureMode
        ) {
            try {
                enterPictureInPictureMode(
                    PictureInPictureParams.Builder().setAspectRatio(pipAspect).build(),
                )
            } catch (_: Exception) {}
        }
    }

    // Known external video players (package -> display label).
    private val knownPlayers = linkedMapOf(
        "com.mxtech.videoplayer.ad" to "MX Player",
        "com.mxtech.videoplayer.pro" to "MX Player Pro",
        "org.videolan.vlc" to "VLC",
        "is.xyz.mpv" to "mpv",
        "com.brouken.player" to "Just Player",
        "dev.anilbeesetti.nextplayer" to "Next Player",
        // SPlayer ships under two package ids (Play Store "All Video Player" and
        // the alt-store "Fast Video Player"); list both so whichever the user has
        // installed is detected. installedPlayers() filters to the present one.
        "com.young.simple.player" to "SPlayer",
        "com.ttee.leeplayer" to "SPlayer",
    )

    private fun installedPlayers(): List<Map<String, String>> {
        val out = mutableListOf<Map<String, String>>()
        for ((pkg, label) in knownPlayers) {
            try {
                packageManager.getPackageInfo(pkg, 0)
                out.add(mapOf("package" to pkg, "label" to label))
            } catch (_: Exception) { /* not installed */ }
        }
        return out
    }

    @Suppress("UNCHECKED_CAST")
    private fun launchExternal(call: MethodCall, result: MethodChannel.Result) {
        try {
            val url = call.argument<String>("url")
            if (url == null) { result.success(mapOf("launched" to false)); return }
            val pkg = call.argument<String>("package")
            val title = call.argument<String>("title")
            val headers = call.argument<Map<String, String>>("headers")
            val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
            val subs = call.argument<List<Map<String, String>>>("subtitles")
            val lower = url.lowercase()
            val mime = when {
                lower.contains("m3u8") -> "application/x-mpegURL" // HLS (incl. ?token= URLs)
                lower.contains(".mpd") -> "application/dash+xml"  // MPEG-DASH
                else -> "video/*"
            }

            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(Uri.parse(url), mime)
            if (!pkg.isNullOrEmpty()) intent.setPackage(pkg)
            // No FLAG_ACTIVITY_NEW_TASK: it would break startActivityForResult,
            // and we need the result back to know if the player actually played.
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

            title?.let { intent.putExtra("title", it); intent.putExtra("name", it) }
            if (positionMs > 0) intent.putExtra("position", positionMs.toInt())

            // Headers: MX Player / Just Player read a flat String[] of k,v,k,v.
            if (!headers.isNullOrEmpty()) {
                val arr = ArrayList<String>()
                for ((k, v) in headers) { arr.add(k); arr.add(v) }
                intent.putExtra("headers", arr.toTypedArray())
                headers["User-Agent"]?.let { intent.putExtra("User-Agent", it) }
            }
            // Subtitles: MX-style arrays + VLC single location.
            if (!subs.isNullOrEmpty()) {
                val uris = subs.mapNotNull { it["url"] }.map { Uri.parse(it) }
                if (uris.isNotEmpty()) {
                    intent.putExtra("subs", uris.toTypedArray())
                    intent.putExtra("subs.name", subs.map { it["name"] ?: "Subtitle" }.toTypedArray())
                    intent.putExtra("subtitles_location", subs[0]["url"])
                }
            }

            // Complete any stale pending launch defensively, then wait for this
            // one's result in onActivityResult.
            pendingPlayerResult?.let {
                try { it.success(mapOf("launched" to true, "played" to true)) } catch (_: Exception) {}
            }
            pendingPlayerResult = result
            startActivityForResult(intent, EXT_PLAYER_REQUEST)
        } catch (e: Exception) {
            Log.w(TAG, "launchExternal failed: ${e.message}")
            pendingPlayerResult = null
            result.success(mapOf("launched" to false))
        }
    }

    // Reads a position/duration extra whether the player stored it as Long or Int.
    private fun longExtra(data: Intent, vararg keys: String): Long {
        for (k in keys) {
            val v = data.extras?.get(k)
            if (v is Long) return v
            if (v is Int) return v.toLong()
        }
        return -1L
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXT_PLAYER_REQUEST) return
        val pos = if (data != null) longExtra(data, "position", "extra_position") else -1L
        val dur = if (data != null) longExtra(data, "duration", "extra_duration") else -1L
        // "Played" = the player reported real progress or that it loaded the
        // media. Nothing reported → it failed / was dismissed → Dart falls back.
        val played = pos > 0 || dur > 0
        pendingPlayerResult?.let {
            try {
                it.success(
                    mapOf(
                        "launched" to true,
                        "played" to played,
                        "positionMs" to (if (pos > 0) pos else 0L),
                    ),
                )
            } catch (_: Exception) {}
        }
        pendingPlayerResult = null
    }

    private fun ensureRetriever(
        url: String,
        headers: Map<String, String>?,
    ): MediaMetadataRetriever? {
        if (retriever != null && currentUrl == url) return retriever
        releaseRetriever()
        val r = MediaMetadataRetriever()
        try {
            Log.d(TAG, "setDataSource url=$url headers=${headers?.keys}")
            when {
                url.startsWith("http") -> r.setDataSource(url, headers ?: emptyMap())
                url.startsWith("content://") -> r.setDataSource(this, Uri.parse(url))
                url.startsWith("file://") -> r.setDataSource(url.removePrefix("file://"))
                else -> r.setDataSource(url)
            }
            Log.d(TAG, "setDataSource OK")
        } catch (e: Exception) {
            Log.w(TAG, "setDataSource FAILED: ${e.message}")
            try { r.release() } catch (_: Exception) {}
            return null
        }
        retriever = r
        currentUrl = url
        return r
    }

    private fun extractFrame(
        url: String,
        positionMs: Long,
        headers: Map<String, String>?,
        maxWidth: Int,
    ): ByteArray? {
        return try {
            val r = ensureRetriever(url, headers) ?: return null
            val timeUs = positionMs * 1000L
            val bmp: Bitmap = (
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    r.getScaledFrameAtTime(
                        timeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        maxWidth,
                        maxWidth,
                    )
                } else {
                    r.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                        ?.let { scaleDown(it, maxWidth) }
                }
            ) ?: run {
                Log.w(TAG, "frame NULL (decoder returned no bitmap) pos=${positionMs}ms")
                return null
            }
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 70, out)
            bmp.recycle()
            val bytes = out.toByteArray()
            Log.d(TAG, "frame OK pos=${positionMs}ms bytes=${bytes.size}")
            bytes
        } catch (e: Exception) {
            Log.w(TAG, "frame FAILED pos=${positionMs}ms: ${e.message}")
            null
        }
    }

    private fun scaleDown(src: Bitmap, maxWidth: Int): Bitmap {
        if (src.width <= maxWidth) return src
        val ratio = src.height.toFloat() / src.width.toFloat()
        val h = (maxWidth * ratio).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(src, maxWidth, h, true)
        if (scaled != src) src.recycle()
        return scaled
    }

    private fun releaseRetriever() {
        try { retriever?.release() } catch (_: Exception) {}
        retriever = null
        currentUrl = null
    }

    override fun onDestroy() {
        releaseRetriever()
        executor.shutdown()
        csExecutor.shutdown()
        csReadPool.shutdown()
        super.onDestroy()
    }

    // ── Background "new episode" subscriptions (CloudStream-style) ─────────────

    /** Merge the CS subscriptions mirrored from Dart into the native store,
     *  PRESERVING the background worker's advanced episode counts (only brand-new
     *  subs take the incoming baseline), then (re)schedule the periodic worker. */
    private fun mergeSubscriptions(incoming: List<Map<String, Any?>>) {
        val prefs = getSharedPreferences("zangetsu_cs", android.content.Context.MODE_PRIVATE)
        val existing = runCatching {
            org.json.JSONArray(prefs.getString("subscriptions", "[]"))
        }.getOrDefault(org.json.JSONArray())
        val counts = HashMap<String, Int>()
        for (i in 0 until existing.length()) {
            val o = existing.getJSONObject(i)
            counts["${o.optString("apiName")}|${o.optString("url")}"] = o.optInt("lastCount", 0)
        }
        val merged = org.json.JSONArray()
        for (m in incoming) {
            val apiName = m["apiName"]?.toString() ?: continue
            val url = m["url"]?.toString() ?: continue
            if (apiName.isEmpty() || url.isEmpty()) continue
            val last = counts["$apiName|$url"] ?: ((m["lastCount"] as? Number)?.toInt() ?: 0)
            merged.put(
                org.json.JSONObject()
                    .put("apiName", apiName)
                    .put("url", url)
                    .put("title", m["title"]?.toString() ?: "")
                    .put("lastCount", last),
            )
        }
        prefs.edit().putString("subscriptions", merged.toString()).apply()
        scheduleSubscriptionWorker(merged.length() > 0)
    }

    private fun scheduleSubscriptionWorker(hasSubs: Boolean) {
        val wm = WorkManager.getInstance(applicationContext)
        if (!hasSubs) {
            wm.cancelUniqueWork("zangetsu_sub_check")
            return
        }
        val req = PeriodicWorkRequestBuilder<SubscriptionWorker>(6, TimeUnit.HOURS)
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .build()
        wm.enqueueUniquePeriodicWork(
            "zangetsu_sub_check",
            ExistingPeriodicWorkPolicy.KEEP,
            req,
        )
    }
}
