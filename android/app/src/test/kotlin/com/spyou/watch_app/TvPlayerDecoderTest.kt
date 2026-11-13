package com.spyou.watch_app

import android.content.Context
import android.content.Intent
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.test.core.app.ApplicationProvider
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.NextRenderersFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class TvPlayerDecoderTest {
    @Test fun defaultEnablesHardwareFirstWithSoftwareDecoders() {
        assertHardwareFirst(factory(null))
    }

    @Test fun explicitHardwareFirstUsesTheSamePriority() {
        assertHardwareFirst(factory(TvPlayerActivity.DECODER_MODE_HARDWARE_FIRST))
    }

    @Test fun hardwareOnlyRemainsAvailable() {
        val factory = factory(TvPlayerActivity.DECODER_MODE_HARDWARE_ONLY)
        assertFalse(factory is NextRenderersFactory)
        assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF,
            setting(factory, "extensionRendererMode"))
    }

    @Test fun softwareFirstRemainsAvailableWithFallback() {
        val factory = factory(TvPlayerActivity.DECODER_MODE_SOFTWARE_FIRST)
        assertTrue(factory is NextRenderersFactory)
        assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER,
            setting(factory, "extensionRendererMode"))
        assertEquals(true, setting(factory, "enableDecoderFallback"))
    }

    private fun assertHardwareFirst(factory: DefaultRenderersFactory) {
        assertTrue(factory is NextRenderersFactory)
        assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON,
            setting(factory, "extensionRendererMode"))
        assertEquals(true, setting(factory, "enableDecoderFallback"))
    }

    private fun factory(mode: Int?): DefaultRenderersFactory {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, TvPlayerActivity::class.java)
        if (mode != null) intent.putExtra(TvPlayerActivity.EXTRA_DECODER_MODE, mode)
        val activity = Robolectric.buildActivity(TvPlayerActivity::class.java, intent).get()
        return TvPlayerActivity::class.java.getDeclaredMethod("renderersFactory").apply {
            isAccessible = true
        }.invoke(activity) as DefaultRenderersFactory
    }

    private fun setting(factory: DefaultRenderersFactory, name: String): Any =
        DefaultRenderersFactory::class.java.getDeclaredField(name).apply {
            isAccessible = true
        }.get(factory)!!
}
