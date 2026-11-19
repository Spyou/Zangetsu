package com.spyou.watch_app

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.roundToInt

/**
 * The frame's average color, pushed warm and lifted — same formula as the
 * Flutter player's ambientGlowColor (watch_page_info.dart): this is a mood
 * glow, not a blurred photo of the frame. [top] is the boosted color;
 * [bottom] is its darker twin (0.55x) — same pairing mpv's radial glow uses.
 */
fun ambientGlowColor(bmp: Bitmap): Pair<Int, Int> {
    if (bmp.width <= 0 || bmp.height <= 0) return Color.BLACK to Color.BLACK
    val pixels = IntArray(bmp.width * bmp.height)
    bmp.getPixels(pixels, 0, bmp.width, 0, 0, bmp.width, bmp.height)
    return ambientGlowColors(pixels)
}

/** Pure part of [ambientGlowColor], unit-testable without a Bitmap. */
fun ambientGlowColors(pixels: IntArray): Pair<Int, Int> {
    var r = 0L
    var g = 0L
    var b = 0L
    var n = 0L
    for (px in pixels) {
        if (((px ushr 24) and 0xFF) < 128) continue
        r += (px shr 16) and 0xFF
        g += (px shr 8) and 0xFF
        b += px and 0xFF
        n++
    }
    if (n == 0L) return 0xFF000000.toInt() to 0xFF000000.toInt()
    val avgR = (r / n).toInt()
    val avgG = (g / n).toInt()
    val avgB = (b / n).toInt()
    val l = (avgR + avgG + avgB) / 3
    fun boost(v: Int) = (l + (v - l) * 1.5).roundToInt() + 22
    val tr = boost(avgR).coerceIn(0, 255)
    val tg = boost(avgG).coerceIn(0, 255)
    val tb = boost(avgB).coerceIn(0, 255)
    fun rgb(r0: Int, g0: Int, b0: Int) = (0xFF shl 24) or (r0 shl 16) or (g0 shl 8) or b0
    return rgb(tr, tg, tb) to rgb(
        (tr * 0.55).roundToInt(),
        (tg * 0.55).roundToInt(),
        (tb * 0.55).roundToInt(),
    )
}

/** Centered crop of a full-view sample that excludes letterbox/pillarbox
 * bars, so the glow averages the picture and not the black around it. */
fun videoSampleRect(viewW: Int, viewH: Int, videoW: Int, videoH: Int): IntArray {
    if (viewW <= 0 || viewH <= 0 || videoW <= 0 || videoH <= 0) {
        return intArrayOf(0, 0, viewW, viewH)
    }
    val scale = minOf(viewW.toDouble() / videoW, viewH.toDouble() / videoH)
    val w = (videoW * scale).roundToInt().coerceIn(1, viewW)
    val h = (videoH * scale).roundToInt().coerceIn(1, viewH)
    return intArrayOf((viewW - w) / 2, (viewH - h) / 2, w, h)
}

/** [color] with its own RGB kept, alpha replaced by [alpha] (0-255). */
fun withAlpha(color: Int, alpha: Int): Int =
    Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
