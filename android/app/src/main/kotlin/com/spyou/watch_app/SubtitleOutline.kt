package com.spyou.watch_app

import android.graphics.Canvas
import android.graphics.Paint
import android.text.SpannableString
import android.text.Spanned
import android.text.TextDirectionHeuristics
import android.text.style.ReplacementSpan
import androidx.media3.common.text.Cue
import kotlin.math.ceil

/**
 * Draws subtitle text with a real, adjustable outline.
 *
 * Media3's own outline is one fixed thin width, so the outline-width slider and
 * the Soft / Bold / Glow presets all looked the same on the native player. Here
 * every word is drawn by a span that strokes it at the chosen width first, then
 * fills it. The numbers mirror `libassOutline()` in subtitle_style.dart (the MPV
 * player's renderer), so the same setting looks the same in both.
 */
object SubtitleOutline {

    /** Sizes are "per 22px of text", the size the style preview is drawn at. */
    data class Look(val border: Float, val blur: Float, val shadow: Float)

    fun look(type: String, width: Float): Look {
        val w = width.coerceIn(0f, 8f)
        return when (type) {
            "none" -> Look(0f, 0f, 0f)
            "outline" -> Look(w, 0f, 0f)
            "bold" -> Look(w * 1.8f, 0f, 0f)
            "shadow" -> Look(w * 0.6f, 0f, w)
            "glow" -> Look(w * 0.8f, 6f + w * 2f, 0f)
            // "soft" and anything unknown: the legacy soft halo.
            else -> Look(w * 0.5f, 3f + w, 0f)
        }
    }

    /** Text cues get the outline; picture cues (PGS and friends) pass through. */
    fun apply(cues: List<Cue>, look: Look, color: Int): List<Cue> {
        val plain = look.border <= 0f && look.blur <= 0f && look.shadow <= 0f
        return cues.map { cue ->
            val text = cue.text ?: return@map cue
            // Always plain text: whatever styling the file carried is dropped.
            cue.buildUpon()
                .setText(if (plain) text.toString() else outlined(text.toString(), look, color))
                .build()
        }
    }

    /** Each word is its own span so lines still wrap between words. */
    internal fun outlined(text: String, look: Look, color: Int): SpannableString {
        val out = SpannableString(text)
        var i = 0
        while (i < text.length) {
            if (text[i].isWhitespace()) { i++; continue }
            var j = i
            while (j < text.length && !text[j].isWhitespace()) j++
            out.setSpan(OutlinedWordSpan(look, color, TextDirectionHeuristics.FIRSTSTRONG_LTR.isRtl(text, i, j - i)), i, j, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            i = j
        }
        return out
    }

    private class OutlinedWordSpan(
        private val look: Look,
        private val color: Int,
        private val rtl: Boolean,
    ) : ReplacementSpan() {

        override fun getSize(
            paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?,
        ): Int {
            fm?.let { paint.getFontMetricsInt(it) }
            return ceil(paint.getRunAdvance(text, start, end, start, end, rtl, end)).toInt()
        }

        override fun draw(
            canvas: Canvas, text: CharSequence, start: Int, end: Int,
            x: Float, top: Int, y: Int, bottom: Int, paint: Paint,
        ) {
            val k = paint.textSize / 22f
            val halo = Paint(paint)
            halo.color = color
            if (look.border > 0f) {
                halo.style = Paint.Style.STROKE
                halo.strokeJoin = Paint.Join.ROUND
                halo.strokeWidth = look.border * k * 2f
            }
            if (look.blur > 0f) {
                halo.setShadowLayer(look.blur * k, 0f, 0f, color)
            } else if (look.shadow > 0f) {
                halo.setShadowLayer(1.5f * k, look.shadow * k, look.shadow * k, 0xB3000000.toInt())
            }
            // Shape both passes in the same direction so Arabic letters join
            // and their marks stay attached to the outlined glyphs.
            canvas.drawTextRun(text, start, end, start, end, x, y.toFloat(), rtl, halo)
            canvas.drawTextRun(text, start, end, start, end, x, y.toFloat(), rtl, paint)
        }
    }
}
