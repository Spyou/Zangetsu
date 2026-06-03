package com.spyou.watch_app

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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
    }

    private fun ensureRetriever(
        url: String,
        headers: Map<String, String>?,
    ): MediaMetadataRetriever? {
        if (retriever != null && currentUrl == url) return retriever
        releaseRetriever()
        val r = MediaMetadataRetriever()
        try {
            when {
                url.startsWith("http") -> r.setDataSource(url, headers ?: emptyMap())
                url.startsWith("content://") -> r.setDataSource(this, Uri.parse(url))
                url.startsWith("file://") -> r.setDataSource(url.removePrefix("file://"))
                else -> r.setDataSource(url)
            }
        } catch (e: Exception) {
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
            ) ?: return null
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 70, out)
            bmp.recycle()
            out.toByteArray()
        } catch (e: Exception) {
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
