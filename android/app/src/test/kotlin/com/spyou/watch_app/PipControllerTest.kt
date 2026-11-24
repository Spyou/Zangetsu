package com.spyou.watch_app

import android.app.Activity
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class PipControllerTest {
    private val pip = PipController(Robolectric.buildActivity(Activity::class.java).get())

    @Test fun `stopping after PiP entry reports dismissal once`() {
        pip.onEntered()
        assertTrue(pip.consumeDismissal())
        assertFalse(pip.consumeDismissal())
    }

    @Test fun `resuming fullscreen clears PiP dismissal tracking`() {
        pip.onEntered()
        pip.onResumed()
        assertFalse(pip.consumeDismissal())
    }

    @Test fun `stopping without entering PiP is a regular background transition`() {
        assertFalse(pip.consumeDismissal())
    }
}
