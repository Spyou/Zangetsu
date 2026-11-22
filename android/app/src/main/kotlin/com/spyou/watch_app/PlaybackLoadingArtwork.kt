package com.spyou.watch_app

import android.animation.ObjectAnimator
import android.animation.PropertyValuesHolder
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.AttributeSet
import android.widget.FrameLayout
import android.widget.ImageView
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

internal fun ImageView.loadPlaybackArtwork(
    url: String?,
    headers: Map<String, String> = emptyMap(),
    onLoaded: () -> Unit = {},
) {
    if (url.isNullOrBlank()) return
    tag = url
    Thread {
        val bitmap = readPlaybackArtwork(url, headers) ?: return@Thread
        post {
            if (isAttachedToWindow && tag == url) {
                setImageBitmap(bitmap)
                onLoaded()
            }
        }
    }.start()
}

private fun readPlaybackArtwork(url: String, headers: Map<String, String>): Bitmap? = runCatching {
    val connection = URL(url).openConnection() as HttpURLConnection
    try {
        if (headers.isNotEmpty()) connection.instanceFollowRedirects = false
        connection.connectTimeout = 5_000
        connection.readTimeout = 5_000
        for ((key, value) in headers) connection.setRequestProperty(key, value)
        val bytes = connection.inputStream.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (output.size() + count > 4 * 1024 * 1024) return@runCatching null
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return@runCatching null
        options.inJustDecodeBounds = false
        options.inSampleSize = 1
        while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 1080) {
            options.inSampleSize *= 2
        }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    } finally {
        connection.disconnect()
    }
}.getOrNull()

class PlaybackTitlePulse @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {
    private var pulse: ObjectAnimator? = null

    fun startPulse() {
        stopPulse()
        if (android.os.Build.VERSION.SDK_INT >= 26 && !ValueAnimator.areAnimatorsEnabled()) return
        pulse = ObjectAnimator.ofPropertyValuesHolder(
            this,
            PropertyValuesHolder.ofFloat(SCALE_X, 1f, 1.035f),
            PropertyValuesHolder.ofFloat(SCALE_Y, 1f, 1.035f),
        ).apply {
            duration = 1_400
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            start()
        }
    }

    fun stopPulse() {
        pulse?.cancel()
        pulse = null
        scaleX = 1f
        scaleY = 1f
    }

    override fun onDetachedFromWindow() {
        stopPulse()
        super.onDetachedFromWindow()
    }
}
