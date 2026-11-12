package com.spyou.watch_app

import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl

/**
 * Builds the ExoPlayer [LoadControl] for the user's buffer setting.
 *
 * Both ExoPlayer sites — the [ExoPlayerView] PlatformView and the fully-native
 * [TvPlayerActivity] — used to call `ExoPlayer.Builder(...).build()` with no
 * LoadControl, so they ran on the media3 default (~50s) and Settings → Playback
 * → Buffer length had no effect on a TV at all. The values arrive already
 * resolved from Dart (`PlaybackPrefs.exo*For`), so the preset→number mapping
 * lives in one place and stays testable there rather than being duplicated in
 * Kotlin.
 *
 * Every value is optional: pass 0 (or nothing) and that knob keeps the media3
 * default, which is exactly the old behaviour.
 */
@UnstableApi
object BufferPresets {
    fun loadControl(
        minBufferMs: Int,
        maxBufferMs: Int,
        targetBufferBytes: Int,
        backBufferMs: Int,
        maxHeapBytes: Long? = null,
    ): LoadControl {
        val b = DefaultLoadControl.Builder()
        if (maxBufferMs > 0) {
            // media3 asserts min <= max and playback-buffer <= min, so clamp
            // rather than trust the caller: a bad pref must not crash playback.
            val max = maxBufferMs
            val min = minBufferMs.coerceIn(1, max)
            val forPlayback =
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS.coerceAtMost(min)
            val afterRebuffer =
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS
                    .coerceAtMost(min)
            b.setBufferDurationsMs(min, max, forPlayback, afterRebuffer)
        }
        // Native phone buffers share the Java heap with the rest of the app.
        val byteLimit = maxHeapBytes?.let {
            (it / 4).coerceIn(64 * 1024L, Int.MAX_VALUE.toLong()).toInt()
        }
        val target = when {
            byteLimit == null -> targetBufferBytes
            targetBufferBytes > 0 -> minOf(targetBufferBytes, byteLimit)
            else -> byteLimit
        }
        if (target > 0) b.setTargetBufferBytes(target)
        if (byteLimit != null) b.setPrioritizeTimeOverSizeThresholds(false)
        val back = if (byteLimit == null) backBufferMs else minOf(backBufferMs, 10_000)
        // Keep a short buffered rewind without retaining a large 4K history.
        if (back > 0) b.setBackBuffer(back, true)
        return b.build()
    }

    /** Reads the four values out of a Flutter creation-params / method-call map. */
    fun fromMap(m: Map<*, *>?): LoadControl = loadControl(
        (m?.get("minBufferMs") as? Number)?.toInt() ?: 0,
        (m?.get("maxBufferMs") as? Number)?.toInt() ?: 0,
        (m?.get("targetBufferBytes") as? Number)?.toInt() ?: 0,
        (m?.get("backBufferMs") as? Number)?.toInt() ?: 0,
    )
}
