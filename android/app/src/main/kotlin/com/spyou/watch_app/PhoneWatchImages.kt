package com.spyou.watch_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import android.widget.ImageView
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Small, session-scoped thumbnails; recycled rows never receive stale artwork. */
internal class PhoneWatchImages(context: Context, private val headers: Map<String, String> = emptyMap()) {
    private val cache = object : LruCache<String, Bitmap>(4 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }
    private val pool = ThreadPoolExecutor(2, 2, 0, TimeUnit.SECONDS, ArrayBlockingQueue(24),
        ThreadPoolExecutor.DiscardOldestPolicy())
    private val targetWidth = (320 * context.resources.displayMetrics.density.coerceAtMost(1f)).toInt()
    @Volatile private var closed = false
    fun clear(view: ImageView) { view.setTag(R.id.watch_thumbnail_request, null); view.setImageDrawable(null) }
    fun load(view: ImageView, url: String) {
        clear(view)
        if (closed || !(url.startsWith("https://") || url.startsWith("http://"))) return
        view.setTag(R.id.watch_thumbnail_request, url)
        cache.get(url)?.let { view.setImageBitmap(it); return }
        pool.execute {
            if (closed || view.getTag(R.id.watch_thumbnail_request) != url) return@execute
            val bitmap = runCatching {
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = 6000
                connection.readTimeout = 6000
                headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
                val bytes = try {
                    connection.inputStream.use { input ->
                        val out = ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val size = input.read(buffer)
                            if (size < 0) break
                            if (out.size() + size > 8 * 1024 * 1024) error("Thumbnail too large")
                            out.write(buffer, 0, size)
                        }
                        out.toByteArray()
                    }
                } finally { connection.disconnect() }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                val options = BitmapFactory.Options().apply {
                    while (bounds.outWidth / (inSampleSize.coerceAtLeast(1) * 2) >= targetWidth ||
                        bounds.outHeight / (inSampleSize.coerceAtLeast(1) * 2) >= 512) {
                        inSampleSize = inSampleSize.coerceAtLeast(1) * 2
                    }
                }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            }.getOrNull() ?: return@execute
            if (closed) return@execute
            cache.put(url, bitmap)
            view.post { if (!closed && view.getTag(R.id.watch_thumbnail_request) == url) view.setImageBitmap(bitmap) }
        }
    }
    fun close() { closed = true; pool.shutdownNow(); cache.evictAll() }
}
