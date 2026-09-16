package com.spyou.watch_app.tiles

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer

/**
 * Exposes tiled page decoding to Dart over a MethodChannel named
 * "zangetsu/tiles", backed by [BitmapRegionDecoder] (API 10+) rather than the
 * AImageDecoder NDK API (API 30+) the native shim this replaces used — the
 * whole point of the swap is to reach the low-memory phones that API floor
 * shut out.
 *
 * Method surface:
 *  - `openPage`   {path:String}                 -> {width, height} | null
 *  - `decodeTile` {path, x, y, w, h, sample:Int} -> {bytes, width, height} | null
 *  - `closePage`  {path:String}                 -> null
 *
 * A MethodChannel handler runs on the platform main thread, and decoding
 * there would block the UI. Every call below hops onto [scope] (IO) for the
 * actual work and replies on the main thread — `MethodChannel.Result` must be
 * answered there.
 */
class TileBridge(private val scope: CoroutineScope) {

    companion object {
        /** Open pages kept alive at once — mirrors the reader's own strip size. */
        private const val CAPACITY = 10
    }

    // accessOrder=true so a plain get() already counts as "touched"; the
    // entry that falls out of removeEldestEntry is recycled immediately so
    // its native pixel memory is freed rather than waiting on GC. Guarded by
    // [lock] — [attach]'s handlers run on a shared IO dispatcher, so more
    // than one call can be inside this class' methods at the same time.
    private val lock = Any()
    private val pages = object : LinkedHashMap<String, BitmapRegionDecoder>(16, 0.75f, true) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<String, BitmapRegionDecoder>,
        ): Boolean {
            if (size <= CAPACITY) return false
            eldest.value.recycle()
            return true
        }
    }

    fun attach(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "openPage" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        val meta = openPage(path)
                        withContext(Dispatchers.Main) { result.success(meta) }
                    }
                }

                "decodeTile" -> {
                    val path = call.argument<String>("path")
                    val x = call.argument<Int>("x")
                    val y = call.argument<Int>("y")
                    val w = call.argument<Int>("w")
                    val h = call.argument<Int>("h")
                    val sample = call.argument<Int>("sample") ?: 1
                    if (path.isNullOrBlank() || x == null || y == null || w == null || h == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        val tile = decodeTile(path, x, y, w, h, sample)
                        withContext(Dispatchers.Main) { result.success(tile) }
                    }
                }

                "closePage" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    scope.launch(Dispatchers.IO) {
                        closePage(path)
                        withContext(Dispatchers.Main) { result.success(null) }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION") // newInstance(String) is deprecated in favour of the
    // InputStream overload (API 31+), but a plain file path is all callers have
    // here and the deprecated overload still works back to API 10.
    private fun openPage(path: String): Map<String, Int>? = synchronized(lock) {
        pages[path]?.let { return@synchronized mapOf("width" to it.width, "height" to it.height) }
        val decoder = try {
            BitmapRegionDecoder.newInstance(path, false)
        } catch (e: Exception) {
            null
        } ?: return@synchronized null
        pages[path] = decoder
        mapOf("width" to decoder.width, "height" to decoder.height)
    }

    private fun decodeTile(
        path: String,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        sample: Int,
    ): Map<String, Any>? = synchronized(lock) {
        if (w <= 0 || h <= 0) return@synchronized null

        // decodeTile can be asked for a page openPage never saw, or one the
        // LRU already evicted since — open it on demand rather than refusing,
        // same as the isolate this replaces used to do.
        val decoder = pages[path] ?: run { openPage(path); pages[path] }
            ?: return@synchronized null

        // Clamp the rect to the image bounds instead of refusing an
        // overshooting one: the tile pyramid's edge tiles are legitimately
        // smaller than a full tile and routinely ask for a rect that runs
        // past the image edge.
        val rect = Rect(x, y, x + w, y + h)
        if (!rect.intersect(0, 0, decoder.width, decoder.height)) return@synchronized null

        val options = BitmapFactory.Options().apply {
            inSampleSize = sample.coerceAtLeast(1)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = try {
            decoder.decodeRegion(rect, options)
        } catch (e: Exception) {
            null
        } ?: return@synchronized null

        val bw = bitmap.width
        val bh = bitmap.height
        // ARGB_8888's bytes in memory are RGBA order, which is what
        // ui.decodeImageFromPixels wants on the Dart side with
        // ui.PixelFormat.rgba8888.
        val buffer = ByteBuffer.allocate(bw * bh * 4)
        bitmap.copyPixelsToBuffer(buffer)
        bitmap.recycle()
        mapOf("bytes" to buffer.array(), "width" to bw, "height" to bh)
    }

    private fun closePage(path: String) = synchronized(lock) {
        pages.remove(path)?.recycle()
    }
}
