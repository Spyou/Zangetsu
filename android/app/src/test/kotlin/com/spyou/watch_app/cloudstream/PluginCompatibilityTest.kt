package com.spyou.watch_app.cloudstream

import com.lagradost.cloudstream3.plugins.Plugin
import java.lang.reflect.Modifier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PluginCompatibilityTest {
    @Test
    fun `compose settings dependencies are available to plugins`() {
        for (name in listOf(
            "androidx.compose.runtime.internal.ComposableLambdaKt",
            "androidx.compose.ui.platform.ComposeView",
            "androidx.compose.material3.MaterialThemeKt",
            "androidx.activity.compose.BackHandlerKt",
        )) {
            Class.forName(name, false, Plugin::class.java.classLoader)
        }
        val colors = Class.forName("androidx.compose.material3.ColorSchemeKt")
        assertTrue(colors.declaredMethods.any {
            it.name == "darkColorScheme-_VG5OTI\$default"
        })
    }

    @Test
    fun `plugins can read the base class stability field`() {
        val field = Plugin::class.java.getField("\$stable")

        assertEquals(Int::class.javaPrimitiveType, field.type)
        assertTrue(Modifier.isStatic(field.modifiers))
        assertTrue(Modifier.isFinal(field.modifiers))
        assertEquals(8, field.getInt(null))
    }
}
