package com.spyou.watch_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Log
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
    private val uiHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val giveUpRunnable = Runnable {
        imageBox.visibility = View.GONE
        spinnerAnim.cancel()
    }
    private val cache = LinkedHashMap<Long, Bitmap>(48, .75f, true)
    private var source: Source? = null
    private var busy = false
    private var closed = false
    private var target: Long? = null
    private var pending: Long? = null
    private var lastSample: Long? = null
    private val warmQueue = ArrayDeque<Long>()
    private var lastWarmBucket: Long? = null

    private val image = ImageView(root.context).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
        visibility = View.GONE
    }
    // Platform ProgressBar drawables on this device/ROM turned out to be a
    // closed, rotationally-symmetric ring — spinning it (or its own broken
    // indeterminate animation) produces no visible change at all. Drawing a
    // partial arc ourselves guarantees the rotation is actually visible.
    private class Spinner(context: android.content.Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            color = Color.WHITE
        }
        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            paint.strokeWidth = w / 8f
        }
        override fun onDraw(canvas: Canvas) {
            val inset = paint.strokeWidth / 2 + 1f
            val rect = RectF(inset, inset, width - inset, height - inset)
            canvas.drawArc(rect, 0f, 270f, false, paint)
        }
    }
    private val spinner = Spinner(root.context)
    private val spinnerAnim = android.animation.ObjectAnimator.ofFloat(spinner, View.ROTATION, 0f, 360f).apply {
        duration = 800
        repeatCount = android.animation.ValueAnimator.INFINITE
        interpolator = android.view.animation.LinearInterpolator()
    }
    private val imageBox = FrameLayout(root.context).apply {
        background = rounded(Color.BLACK, 8)
        clipToOutline = true
        addView(image, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        addView(spinner, FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER))
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
        addView(imageBox, LinearLayout.LayoutParams(dp(168), dp(94)).apply { bottomMargin = dp(4) })
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
        warmQueue.clear()
        lastWarmBucket = null
        if (source?.online == true) releaseOnlineSession()
        source = next
    }

    /** Pre-decode the frame near the current playback position (and its
     * neighbours) while playing, so the first scrub touch already has a hit
     * instead of paying the network round-trip live. */
    fun warm(position: Long, duration: Long) {
        val current = source ?: return
        if (!current.online || duration <= 0) return
        val center = position / 2000 * 2000
        if (center == lastWarmBucket) return
        lastWarmBucket = center
        warmQueue.clear()
        for (t in longArrayOf(center, center + 2000, center - 2000)) {
            if (t in 0 until duration && !cache.containsKey(t)) warmQueue.addLast(t)
        }
        requestNext()
    }

    fun show(position: Long, label: String) {
        if (source == null) return
        timestamp.text = label
        bubble.bringToFront()
        bubble.visibility = View.VISIBLE
        // positionBubble() must track every pixel of the drag for a smooth
        // feel, but the cache lookup / decode-request work below only needs
        // to run once per 2s bucket — without this a fast drag floods the
        // main thread with redundant work every touch-move tick (far more
        // often than the display refreshes), which was starving the spinner
        // animation of its own frame callbacks.
        positionBubble()
        val sample = position / 2000 * 2000
        if (sample == lastSample) return
        lastSample = sample
        target = sample
        val closest = cache.keys.minByOrNull { kotlin.math.abs(it - sample) }
        showBitmap(closest?.let { cache[it] })
        pending = if (closest == sample) null else sample
        requestNext()
    }

    fun hide() {
        target = null
        pending = null
        lastSample = null
        bubble.visibility = View.INVISIBLE
        uiHandler.removeCallbacks(giveUpRunnable)
        spinnerAnim.cancel()
        image.setImageBitmap(null)
        image.visibility = View.GONE
        spinner.visibility = View.GONE
        imageBox.visibility = View.VISIBLE
    }

    fun close() {
        closed = true
        hide()
        cache.clear()
        warmQueue.clear()
        if (source?.online == true) releaseOnlineSession()
        worker.shutdown()
    }

    private fun releaseOnlineSession() {
        worker.execute { runCatching { keyframethumbs.Native.releaseThumbnailSession() } }
    }

    private fun requestNext() {
        if (busy || closed) return
        val current = source ?: return
        val position = pending ?: warmQueue.removeFirstOrNull() ?: return
        pending = null
        busy = true
        worker.execute {
            val bitmap = runCatching { decode(current, position) }
                .onFailure { Log.e("PhoneSeekPreview", "thumbnail decode failed for $position", it) }
                .getOrNull()
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
        uiHandler.removeCallbacks(giveUpRunnable)
        imageBox.visibility = View.VISIBLE
        image.setImageBitmap(bitmap)
        image.visibility = if (bitmap == null) View.GONE else View.VISIBLE
        spinner.visibility = if (bitmap == null) View.VISIBLE else View.GONE
        if (bitmap == null) {
            if (!spinnerAnim.isStarted) spinnerAnim.start()
            // A persistently failing/slow source shouldn't spin forever —
            // give up and fall back to a plain time bubble, same as mpv.
            uiHandler.postDelayed(giveUpRunnable, GIVE_UP_MS)
        } else {
            spinnerAnim.cancel()
        }
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

    private companion object {
        const val GIVE_UP_MS = 5_000L
    }
}
