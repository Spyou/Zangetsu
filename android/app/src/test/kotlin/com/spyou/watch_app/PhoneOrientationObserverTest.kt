package com.spyou.watch_app

import android.content.Context
import android.content.res.Configuration
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PhoneOrientationObserverTest {
    @Test
    fun `only settled turns resume auto rotation`() {
        val turns = mutableListOf<Int>()
        val observer = PhoneOrientationObserver(ApplicationProvider.getApplicationContext<Context>()) {
            turns += it
        }
        for (angle in listOf(-1, 0, 5, 359, 45, 90, 95, 130, 180, 185, 270)) {
            observer.onOrientationChanged(angle)
        }
        assertEquals(listOf(
            Configuration.ORIENTATION_PORTRAIT,
            Configuration.ORIENTATION_LANDSCAPE,
            Configuration.ORIENTATION_PORTRAIT,
            Configuration.ORIENTATION_LANDSCAPE,
        ), turns)
    }
}
