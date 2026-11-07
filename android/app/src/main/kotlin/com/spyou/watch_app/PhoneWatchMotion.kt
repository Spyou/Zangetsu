package com.spyou.watch_app

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.app.Dialog
import android.content.res.Configuration
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.widget.TextView
import androidx.core.view.doOnNextLayout
import androidx.recyclerview.widget.RecyclerView

/** Portrait-only motion observes controls; playback callbacks still run immediately. */
internal object PhoneWatchMotion {
    fun enabled(view: View) = view.isShown &&
        view.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT &&
        (Build.VERSION.SDK_INT < 26 || ValueAnimator.areAnimatorsEnabled())

    @android.annotation.SuppressLint("ClickableViewAccessibility")
    fun press(view: View) {
        // Return false: the existing click listener owns gestures and accessibility.
        view.setOnTouchListener { _, event ->
            val release = event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL
            if (release || (event.actionMasked == MotionEvent.ACTION_DOWN && enabled(view))) {
                val scale = if (release) 1f else .97f
                view.animate().scaleX(scale).scaleY(scale)
                    .setDuration(if (!enabled(view)) 0 else if (release) 120 else 80).start()
            }
            false
        }
    }

    fun text(view: TextView, value: CharSequence) {
        if (view.text.toString() == value.toString()) return
        view.text = value
        view.animate().cancel()
        if (!enabled(view)) { view.alpha = 1f; view.translationY = 0f; return }
        view.alpha = .7f
        view.translationY = 3 * view.resources.displayMetrics.density
        view.animate().alpha(1f).translationY(0f).setDuration(180)
            .setInterpolator(DecelerateInterpolator()).start()
    }

    fun textColor(view: TextView, color: Int, animate: Boolean) {
        val from = view.currentTextColor
        (view.getTag(R.id.watch_color_motion) as? ValueAnimator)?.cancel()
        if (!animate || !enabled(view) || from == color) { view.setTextColor(color); return }
        tint(view, from, color) { view.setTextColor(it) }
    }

    fun color(view: View, drawable: GradientDrawable, from: Int, to: Int) {
        if (!enabled(view) || from == to) { drawable.setColor(to); return }
        tint(view, from, to) { drawable.setColor(it) }
    }

    private fun tint(view: View, from: Int, to: Int, apply: (Int) -> Unit) {
        (view.getTag(R.id.watch_color_motion) as? ValueAnimator)?.cancel()
        val animator = ValueAnimator.ofObject(ArgbEvaluator(), from, to).apply {
            duration = 180
            addUpdateListener { apply(it.animatedValue as Int) }
        }
        view.setTag(R.id.watch_color_motion, animator)
        animator.start()
    }

    fun resize(view: ViewGroup, change: () -> Unit) {
        val from = view.height
        (view.getTag(R.id.watch_height_motion) as? ValueAnimator)?.cancel()
        change()
        if (!enabled(view) || from <= 0 || view.width <= 0) return
        view.measure(View.MeasureSpec.makeMeasureSpec(view.width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        val to = view.measuredHeight
        if (to == from) return
        view.layoutParams = view.layoutParams.apply { height = from }
        val animator = ValueAnimator.ofInt(from, to).apply {
            duration = 220
            interpolator = DecelerateInterpolator()
            addUpdateListener { view.layoutParams = view.layoutParams.apply { height = it.animatedValue as Int } }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (view.getTag(R.id.watch_height_motion) === animation) {
                        view.layoutParams = view.layoutParams.apply { height = ViewGroup.LayoutParams.WRAP_CONTENT }
                        view.setTag(R.id.watch_height_motion, null)
                    }
                }
            })
        }
        view.setTag(R.id.watch_height_motion, animator)
        animator.start()
    }

    fun enter(dialog: Dialog) {
        val view = dialog.findViewById<View>(android.R.id.content) ?: return
        if (!enabled(view)) return
        view.alpha = .85f
        view.translationY = 8 * view.resources.displayMetrics.density
        view.animate().alpha(1f).translationY(0f).setDuration(180)
            .setInterpolator(DecelerateInterpolator()).start()
    }

    fun viewMode(list: RecyclerView, change: () -> Unit) {
        if (!enabled(list)) { change(); return }
        list.doOnNextLayout {
            for (i in 0 until list.childCount) {
                val row = list.getChildAt(i)
                if (list.getChildAdapterPosition(row) == 0) continue
                val opacity = row.alpha
                row.alpha = .7f * opacity
                row.animate().alpha(opacity).setDuration(180).start()
            }
        }
        change()
    }
}
