package com.spyou.watch_app

import android.content.Context
import android.graphics.Rect
import android.util.AttributeSet
import android.view.View
import android.widget.ScrollView

/**
 * ScrollView that can refuse to scroll — used for the TV player side panel so
 * the "Episodes" header and range rail stay pinned while an inner list scrolls.
 */
class LockedScrollView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : ScrollView(context, attrs) {

    /** When true, focus changes won't move this scroll view. */
    var scrollLocked: Boolean = false

    private var ignoreScrollLock = false

    /** Position the rail without letting focus-driven scroll fight it. */
    fun scrollToIgnoringLock(x: Int, y: Int) {
        ignoreScrollLock = true
        super.scrollTo(x, y)
        ignoreScrollLock = false
    }

    override fun requestChildRectangleOnScreen(
        child: View,
        rectangle: Rect,
        immediate: Boolean,
    ): Boolean {
        if (scrollLocked) return false
        return super.requestChildRectangleOnScreen(child, rectangle, immediate)
    }

    override fun scrollTo(x: Int, y: Int) {
        if (scrollLocked && !ignoreScrollLock) return
        super.scrollTo(x, y)
    }
}
