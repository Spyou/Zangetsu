package com.spyou.watch_app

import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.media3.common.text.Cue
import kotlin.math.max
import kotlin.math.roundToInt

/** Spaces simultaneous TV captions using their wrapped text heights. */
object TvSubtitleCuePositioning {
    fun position(
        cues: List<Cue>,
        positionPercent: Int,
        textSizeFraction: Float,
        width: Int,
        height: Int,
        typeface: Typeface,
    ): List<Cue> {
        if (cues.size < 2 || width <= 0 || height <= 0 || cues.any { it.bitmap != null }) {
            return SubtitleCuePositioning.position(cues, positionPercent, textSizeFraction)
        }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
            textSize = height * textSizeFraction
            this.typeface = typeface
        }
        // Match the subtitle renderer's horizontal text padding and stripped styles.
        val padding = (paint.textSize * 0.125f).roundToInt()
        val heights = cues.map { cue ->
            val size = if (cue.size == Cue.DIMEN_UNSET) 1f else cue.size.coerceIn(0f, 1f)
            val textWidth = ((width - padding * 2) * size).toInt().coerceAtLeast(1)
            StaticLayout.Builder.obtain(cue.text?.toString().orEmpty(), 0,
                cue.text?.length ?: 0, paint, textWidth)
                .setAlignment(cue.textAlignment ?: Layout.Alignment.ALIGN_CENTER)
                .setIncludePad(true)
                .build().height.toFloat()
        }
        val gap = max(2f, paint.textSize * 0.1f)
        val blockHeight = heights.sum() + gap * (cues.size - 1)
        val preferredBottom = height * positionPercent.coerceIn(0, 100) / 100f
        // Move the group down if a high position would clip its upper captions.
        var bottom = max(preferredBottom, blockHeight).coerceAtMost(height.toFloat())
        return cues.mapIndexed { index, cue ->
            val positioned = cue.buildUpon()
                .setLine(bottom / height, Cue.LINE_TYPE_FRACTION)
                .setLineAnchor(Cue.ANCHOR_TYPE_END)
                .build()
            bottom -= heights[index] + gap
            positioned
        }
    }
}
