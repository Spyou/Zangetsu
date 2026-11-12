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
class PhonePlayerDecoderTest {
    @Test
    fun `automatic and hardware plus include software decoders after hardware`() {
        for (mode in listOf(null, "auto", "copy", "hw", "hw+", "unknown")) {
            val factory = factory(mode)
            assertTrue(factory is NextRenderersFactory)
            assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON, setting(factory, "extensionRendererMode"))
            assertEquals(true, setting(factory, "enableDecoderFallback"))
        }
    }

    @Test
    fun `software prefers bundled decoders with platform fallback`() {
        val factory = factory("sw")
        assertTrue(factory is NextRenderersFactory)
        assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER, setting(factory, "extensionRendererMode"))
        assertEquals(true, setting(factory, "enableDecoderFallback"))
    }

    @Test
    fun `hardware uses platform decoders without enabling extensions`() {
        val factory = factory("direct")
        assertFalse(factory is NextRenderersFactory)
        assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF, setting(factory, "extensionRendererMode"))
        assertEquals(true, setting(factory, "enableDecoderFallback"))
    }

    @Test
    fun `older software launches remain compatible and explicit mode wins`() {
        assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER,
            setting(factory(null, legacySoftware = true), "extensionRendererMode"))
        assertEquals(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF,
            setting(factory("direct", legacySoftware = true), "extensionRendererMode"))
    }

    private fun factory(mode: String?, legacySoftware: Boolean = false): DefaultRenderersFactory {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val intent = Intent(context, PhonePlayerActivity::class.java)
            .putExtra("decoderMode", mode)
            .putExtra(PhonePlayerIntent.EXTRA_SW_DECODE, legacySoftware)
        val activity = Robolectric.buildActivity(PhonePlayerActivity::class.java, intent).get()
        return PhonePlayerActivity::class.java.getDeclaredMethod("renderersFactory").apply {
            isAccessible = true
        }.invoke(activity) as DefaultRenderersFactory
    }

    private fun setting(factory: DefaultRenderersFactory, name: String): Any =
        DefaultRenderersFactory::class.java.getDeclaredField(name).apply {
            isAccessible = true
        }.get(factory)!!
}
