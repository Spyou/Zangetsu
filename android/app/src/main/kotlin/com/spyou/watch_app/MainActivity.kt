package com.spyou.watch_app

import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Log
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

    companion object {
        private const val TAG = "SeekPreview"
    }

    // Cached retriever so rapid scrubbing on one title doesn't re-open the
    // source for every frame (setDataSource is expensive, esp. over network).
    private var retriever: MediaMetadataRetriever? = null
    private var currentUrl: String? = null

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
                    "launch" -> result.success(launchExternal(call))
                    else -> result.notImplemented()
                }
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
    private fun launchExternal(call: MethodCall): Boolean {
        return try {
            val url = call.argument<String>("url") ?: return false
            val pkg = call.argument<String>("package")
            val title = call.argument<String>("title")
            val headers = call.argument<Map<String, String>>("headers")
            val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
            val subs = call.argument<List<Map<String, String>>>("subtitles")
            val mime = if (url.contains(".m3u8")) "application/x-mpegURL" else "video/*"

            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(Uri.parse(url), mime)
            if (!pkg.isNullOrEmpty()) intent.setPackage(pkg)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "launchExternal failed: ${e.message}")
            false
        }
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
        super.onDestroy()
    }
}
