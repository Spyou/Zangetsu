package com.spyou.watch_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import java.util.concurrent.Executors

/** Thumbnail overlay for the native phone player's shared portrait/fullscreen seek bar. */
internal class PhoneSeekPreview(
    private val root: FrameLayout,
    private val seek: SeekBar,
) {
    private data class Source(val url: String, val headers: Map<String, String>, val online: Boolean)

    private val worker = Executors.newSingleThreadExecutor()
    private val cache = LinkedHashMap<Long, Bitmap>(48, .75f, true)
    private var source: Source? = null
    private var busy = false
    private var closed = false
    private var target: Long? = null
    private var pending: Long? = null

    private val image = ImageView(root.context).apply {
        background = rounded(Color.BLACK, 8)
        clipToOutline = true
        scaleType = ImageView.ScaleType.CENTER_CROP
        visibility = View.GONE
    }
    private val timestamp = TextView(root.context).apply {
        background = rounded(0xCC000000.toInt(), 6)
        setTextColor(Color.WHITE)
        textSize = 12f
        setPadding(dp(8), dp(3), dp(8), dp(3))
    }
    private val bubble = LinearLayout(root.context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        visibility = View.INVISIBLE
        addView(image, LinearLayout.LayoutParams(dp(168), dp(94)).apply { bottomMargin = dp(4) })
        addView(timestamp, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ))
    }

    init {
        root.addView(bubble, FrameLayout.LayoutParams(dp(168), FrameLayout.LayoutParams.WRAP_CONTENT))
        bubble.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> positionBubble() }
    }

    fun setSource(url: String, headers: Map<String, String>) {
        hide()
        val uri = Uri.parse(url)
        val online = uri.scheme.equals("http", true) || uri.scheme.equals("https", true)
        val next = when {
            online -> Source(url, headers.toMap(), true)
            uri.scheme == "file" || uri.scheme == "content" -> Source(url, emptyMap(), false)
            uri.scheme == null && url.startsWith("/") -> Source(url, emptyMap(), false)
            else -> null
        }
        if (next == source) return
        cache.clear()
        if (source?.online == true) releaseOnlineSession()
        source = next
    }

    fun show(position: Long, label: String) {
        if (source == null) return
        timestamp.text = label
        bubble.bringToFront()
        bubble.visibility = View.VISIBLE
        val sample = position / 2000 * 2000
        target = sample
        val closest = cache.keys.minByOrNull { kotlin.math.abs(it - sample) }
        showBitmap(closest?.let { cache[it] })
        positionBubble()
        pending = if (closest == sample) null else sample
        requestNext()
    }

    fun hide() {
        target = null
        pending = null
        bubble.visibility = View.INVISIBLE
        showBitmap(null)
    }

    fun close() {
        closed = true
        hide()
        cache.clear()
        if (source?.online == true) releaseOnlineSession()
        worker.shutdown()
    }

    private fun releaseOnlineSession() {
        worker.execute { runCatching { keyframethumbs.Native.releaseThumbnailSession() } }
    }

    private fun requestNext() {
        if (busy || closed) return
        val current = source ?: return
        val position = pending ?: return
        pending = null
        busy = true
        worker.execute {
            val bitmap = runCatching { decode(current, position) }.getOrNull()
            root.post {
                busy = false
                if (closed) return@post
                if (source === current && bitmap != null) {
                    cache[position] = bitmap
                    if (cache.size > 48) cache.remove(cache.keys.first())
                    if (pending == position) pending = null
                    target?.let { wanted ->
                        val closest = cache.keys.minByOrNull { kotlin.math.abs(it - wanted) }
                        showBitmap(closest?.let { cache[it] })
                    }
                }
                requestNext()
            }
        }
    }

    private fun decode(source: Source, position: Long): Bitmap? {
        if (source.online) {
            val headers = source.headers.flatMap { (key, value) -> listOf(key, value) }.toTypedArray()
            val jpeg = keyframethumbs.Native.requestThumbnail(source.url, position, headers)
            return BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
        }
        val retriever = MediaMetadataRetriever()
        return try {
            if (source.url.startsWith("/")) retriever.setDataSource(source.url)
            else retriever.setDataSource(root.context, Uri.parse(source.url))
            val mode = MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(position * 1000, mode, 320, 180)
            } else {
                val frame = retriever.getFrameAtTime(position * 1000, mode) ?: return null
                val scale = minOf(320f / frame.width, 180f / frame.height)
                if (scale >= 1f) frame else Bitmap.createScaledBitmap(
                    frame, (frame.width * scale).toInt().coerceAtLeast(1),
                    (frame.height * scale).toInt().coerceAtLeast(1), true,
                ).also { if (it !== frame) frame.recycle() }
            }
        } finally {
            retriever.release()
        }
    }

    private fun showBitmap(bitmap: Bitmap?) {
        image.setImageBitmap(bitmap)
        image.visibility = if (bitmap == null) View.GONE else View.VISIBLE
    }

    private fun positionBubble() {
        val rootLocation = IntArray(2)
        val seekLocation = IntArray(2)
        root.getLocationInWindow(rootLocation)
        seek.getLocationInWindow(seekLocation)
        val track = seek.width - seek.paddingLeft - seek.paddingRight
        val fraction = seek.progress.toFloat() / seek.max.coerceAtLeast(1)
        val center = seekLocation[0] - rootLocation[0] + seek.paddingLeft + track * fraction
        val width = dp(168)
        bubble.x = (center - width / 2f).coerceIn(0f, (root.width - width).coerceAtLeast(0).toFloat())
        bubble.y = (seekLocation[1] - rootLocation[1] - bubble.height - dp(4)).coerceAtLeast(0).toFloat()
    }

    private fun dp(value: Int) = (value * root.resources.displayMetrics.density + .5f).toInt()

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
    }
}
