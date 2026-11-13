package com.spyou.watch_app

import android.content.Context
import android.view.ContextThemeWrapper
import android.view.animation.AnimationUtils
import android.view.animation.Transformation
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhonePlayerTransitionTest {
    @Test
    fun `phone player slides up and back down without fading Detail`() {
        val app = ApplicationProvider.getApplicationContext<Context>()
        val themeId = app.resources.getIdentifier("Theme.PhonePlayer", "style", app.packageName)
        assertNotEquals("Native player needs its own window transition", 0, themeId)
        val context = ContextThemeWrapper(app, themeId)
        val window = context.obtainStyledAttributes(intArrayOf(android.R.attr.windowAnimationStyle))
        val style = window.getResourceId(0, 0)
        window.recycle()
        val attrs = context.obtainStyledAttributes(style, intArrayOf(
            android.R.attr.activityOpenEnterAnimation,
            android.R.attr.activityOpenExitAnimation,
            android.R.attr.activityCloseEnterAnimation,
            android.R.attr.activityCloseExitAnimation,
        ))
        val ids = (0..3).map { attrs.getResourceId(it, 0) }
        attrs.recycle()
        val animations = ids.map { AnimationUtils.loadAnimation(context, it).apply {
            initialize(100, 200, 100, 200)
            startTime = 0
        } }
        val enterStart = Transformation().also { animations[0].getTransformation(0, it) }
        val enterEnd = Transformation().also { animations[0].getTransformation(350, it) }
        val closeStart = Transformation().also { animations[3].getTransformation(0, it) }
        val closeEnd = Transformation().also { animations[3].getTransformation(350, it) }
        val point = floatArrayOf(0f, 0f)
        enterStart.matrix.mapPoints(point)
        assertEquals(200f, point[1], .01f)
        val end = floatArrayOf(0f, 0f)
        enterEnd.matrix.mapPoints(end)
        assertEquals(0f, end[1], .01f)
        val start = floatArrayOf(0f, 0f)
        closeStart.matrix.mapPoints(start)
        assertEquals(0f, start[1], .01f)
        val closed = floatArrayOf(0f, 0f)
        closeEnd.matrix.mapPoints(closed)
        assertEquals(200f, closed[1], .01f)
        for (animation in animations) {
            assertEquals(350L, animation.duration)
            val middle = Transformation().also { animation.getTransformation(175, it) }
            assertEquals(1f, middle.alpha, .001f)
        }
        for (index in listOf(1, 2)) {
            val middle = Transformation().also { animations[index].getTransformation(175, it) }
            assertTrue(middle.matrix.isIdentity)
        }
    }
}
