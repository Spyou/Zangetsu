package com.spyou.watch_app

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The short content-warnings card shown when playback starts: a thin bar grows
 * down the left, the rows (Violence · Moderate …) fade in one by one, hold for
 * about five seconds, then fade out in reverse. Purely visual — it never takes
 * touches and cleans itself up if hidden mid-way.
 */
class ParentalGuideOverlay(context: Context) : LinearLayout(context) {
    private val handler = Handler(Looper.getMainLooper())
    private val bar = View(context)
    private val rows = LinearLayout(context).apply { orientation = VERTICAL }
    private var run = 0

    init {
        orientation = HORIZONTAL
        visibility = GONE
        alpha = 0f
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        bar.setBackgroundColor(Color.WHITE)
        addView(bar)
        addView(rows, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            marginStart = dp(10)
        })
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    /** Plays the card once for [warnings] (label to severity); a new call restarts it. */
    fun show(warnings: List<Pair<String, String>>) {
        hideNow()
        if (warnings.isEmpty()) return
        val token = ++run
        val rowHeight = dp(18)
        val gap = dp(2)
        val count = warnings.size
        val barHeight = rowHeight * count + gap * (count - 1)

        rows.removeAllViews()
        val rowViews = warnings.mapIndexed { i, (label, severity) ->
            TextView(context).apply {
                // dp, not sp: the bar next to the rows is a fixed height, so the text must not scale.
                setTextSize(TypedValue.COMPLEX_UNIT_DIP, 11f)
                gravity = Gravity.CENTER_VERTICAL
                includeFontPadding = false
                setShadowLayer(dp(3).toFloat(), 0f, 0f, 0x99000000.toInt())
                alpha = 0f
                text = SpannableStringBuilder().apply {
                    append(label)
                    setSpan(ForegroundColorSpan(0xD9FFFFFF.toInt()), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    setSpan(StyleSpan(Typeface.BOLD), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    val dot = length
                    append(" · ")
                    setSpan(ForegroundColorSpan(0x66FFFFFF), dot, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    val sev = length
                    append(severity)
                    setSpan(ForegroundColorSpan(0x80FFFFFF.toInt()), sev, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }.also {
                rows.addView(it, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, rowHeight).apply {
                    if (i > 0) topMargin = gap
                })
            }
        }
        bar.layoutParams = LayoutParams(dp(3), barHeight)
        bar.pivotY = 0f
        bar.scaleY = 0f

        visibility = VISIBLE
        animate().alpha(1f).setDuration(300).start()
        bar.animate().scaleY(1f).setDuration(400).start()
        rowViews.forEachIndexed { i, row ->
            handler.postDelayed({
                if (token == run) row.animate().alpha(1f).setDuration(200).start()
            }, 400L + 80L * (i + 1))
        }
        // Hold ~5s after the last row is in, then reverse the whole thing.
        val outAt = 400L + 80L * count + 200L + 5000L
        rowViews.asReversed().forEachIndexed { i, row ->
            handler.postDelayed({
                if (token == run) row.animate().alpha(0f).setDuration(150).start()
            }, outAt + 60L * i)
        }
        val barOut = outAt + 60L * count + 100L
        handler.postDelayed({
            if (token == run) bar.animate().scaleY(0f).setDuration(300).start()
        }, barOut)
        handler.postDelayed({
            if (token == run) animate().alpha(0f).setDuration(200).withEndAction { if (token == run) visibility = GONE }.start()
        }, barOut + 300L)
    }

    /** Drops the card straight away (episode change, PiP, closing). */
    fun hideNow() {
        run++
        handler.removeCallbacksAndMessages(null)
        animate().cancel()
        bar.animate().cancel()
        for (i in 0 until rows.childCount) rows.getChildAt(i).animate().cancel()
        alpha = 0f
        visibility = GONE
    }

    override fun onDetachedFromWindow() {
        hideNow()
        super.onDetachedFromWindow()
    }
}
