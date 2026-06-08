package com.spyou.watch_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Log
import android.util.Rational
import com.spyou.watch_app.cloudstream.PluginHost
import com.spyou.watch_app.cloudstream.RepoManager
import io.flutter.embedding.android.FlutterActivity
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

    // CloudStream bridge: a dedicated single-thread executor (separate from the
    // seek_preview [executor] to avoid contention) plus a lazily-created repo
    // downloader + plugin host, both backed by the application context.
    private val csExecutor = Executors.newSingleThreadExecutor()
    private val repo: RepoManager by lazy { RepoManager(applicationContext) }
    private val host: PluginHost by lazy { PluginHost(applicationContext) }

    companion object {
        private const val TAG = "SeekPreview"
        private const val EXT_PLAYER_REQUEST = 7001
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                    else -> result.notImplemented()
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

        // CloudStream channel: install repos and drive `.cs3` plugins' search /
        // load / loadLinks. All handlers run on [csExecutor] (network + plugin
        // work is blocking) and post back via runOnUiThread; any failure is
        // surfaced to Dart as a "cs_error".
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zangetsu/cloudstream")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "addRepo" -> {
                        val url = call.argument<String>("url")
                        csExecutor.execute {
                            try {
                                val (repoName, plugins) = repo.loadRepo(url ?: "")
                                for (plugin in plugins) {
                                    try {
                                        host.loadPlugin(repo.download(plugin))
                                    } catch (_: Exception) { /* skip a bad plugin */ }
                                }
                                // Report the repo's name + its plugin FILE ids
                                // ("<internalName>@<version>") — these match each
                                // source's `sourcePlugin`, so Dart can group + delete
                                // by repo reliably (handles multi-API plugins).
                                val info = mapOf(
                                    "name" to repoName,
                                    "url" to (url ?: ""),
                                    "files" to plugins.map { "${it.internalName}@${it.version}" },
                                )
                                runOnUiThread { result.success(info) }
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
                    "updateRepo" -> {
                        val url = call.argument<String>("url")
                        csExecutor.execute {
                            try {
                                val (repoName, plugins) = repo.loadRepo(url ?: "")
                                // Drop every cached version of this repo's plugins,
                                // then download + load the current versions fresh.
                                host.deleteByInternalNames(
                                    plugins.map { it.internalName }.toSet(),
                                )
                                for (plugin in plugins) {
                                    try {
                                        host.loadPlugin(repo.download(plugin))
                                    } catch (_: Exception) { /* skip a bad plugin */ }
                                }
                                val info = mapOf(
                                    "name" to repoName,
                                    "url" to (url ?: ""),
                                    "files" to plugins.map { "${it.internalName}@${it.version}" },
                                )
                                runOnUiThread { result.success(info) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "getHome" -> {
                        val name = call.argument<String>("name")
                        csExecutor.execute {
                            try {
                                val res = host.getHome(name ?: "")
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "search" -> {
                        val name = call.argument<String>("name")
                        val query = call.argument<String>("query")
                        csExecutor.execute {
                            try {
                                val res = host.search(name ?: "", query ?: "")
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "load" -> {
                        val name = call.argument<String>("name")
                        val url = call.argument<String>("url")
                        csExecutor.execute {
                            try {
                                val res = host.load(name ?: "", url ?: "")
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
                    }
                    "loadLinks" -> {
                        val name = call.argument<String>("name")
                        val data = call.argument<String>("data")
                        csExecutor.execute {
                            try {
                                val res = host.loadLinks(name ?: "", data ?: "")
                                runOnUiThread { result.success(res) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("cs_error", e.message, null) }
                            }
                        }
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
            val mime = if (url.contains(".m3u8")) "application/x-mpegURL" else "video/*"

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
        super.onDestroy()
    }
}
