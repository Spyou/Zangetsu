package com.spyou.watch_app.aniyomi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure helper logic in [AniyomiExtensionLoader].
 *
 * These tests exercise [AniyomiExtensionLoader.libVersionOf],
 * [AniyomiExtensionLoader.resolveClassName], and
 * [AniyomiExtensionLoader.isLibVersionSupported] — all of which are
 * plain JVM logic with no Android or DexClassLoader dependency.
 *
 * The full DexClassLoad + instantiate happy-path test is marked
 * [@Ignore] below because it requires a real Android runtime to call
 * [PackageManager.getPackageArchiveInfo] and [DexClassLoader]. That
 * path is validated on-device in Task 9.
 */
class AniyomiExtensionLoaderTest {

    // ---------------------------------------------------------------
    // libVersionOf
    // ---------------------------------------------------------------

    @Test
    fun libVersionOf_parses_standard_two_part_name() {
        // "14.17" → substringBeforeLast('.') = "14" → 14.0
        assertEquals(14.0, AniyomiExtensionLoader.libVersionOf("14.17"), 0.0)
    }

    @Test
    fun libVersionOf_parses_exact_lib_version() {
        // "16.0" → substringBeforeLast('.') = "16" → 16.0
        assertEquals(16.0, AniyomiExtensionLoader.libVersionOf("16.0"), 0.0)
    }

    @Test
    fun libVersionOf_parses_lib_16_with_minor() {
        // "16.1" → substringBeforeLast('.') = "16" → 16.0
        assertEquals(16.0, AniyomiExtensionLoader.libVersionOf("16.1"), 0.0)
    }

    @Test
    fun libVersionOf_parses_lib_12_lower_bound() {
        assertEquals(12.0, AniyomiExtensionLoader.libVersionOf("12.5"), 0.0)
    }

    @Test(expected = NumberFormatException::class)
    fun libVersionOf_throws_on_non_numeric() {
        AniyomiExtensionLoader.libVersionOf("abc.def")
    }

    // ---------------------------------------------------------------
    // isLibVersionSupported — range gate 12.0 .. 16.0
    // ---------------------------------------------------------------

    @Test
    fun isLibVersionSupported_accepts_min_bound() {
        assertTrue(AniyomiExtensionLoader.isLibVersionSupported(12.0))
    }

    @Test
    fun isLibVersionSupported_accepts_max_bound() {
        assertTrue(AniyomiExtensionLoader.isLibVersionSupported(16.0))
    }

    @Test
    fun isLibVersionSupported_accepts_mid_range() {
        assertTrue(AniyomiExtensionLoader.isLibVersionSupported(14.0))
    }

    @Test
    fun isLibVersionSupported_rejects_too_new() {
        // lib 17 — beyond ANIME_LIB_VERSION_MAX
        assertFalse(AniyomiExtensionLoader.isLibVersionSupported(17.0))
    }

    @Test
    fun isLibVersionSupported_rejects_too_old() {
        // lib 11 — below ANIME_LIB_VERSION_MIN
        assertFalse(AniyomiExtensionLoader.isLibVersionSupported(11.0))
    }

    // ---------------------------------------------------------------
    // resolveClassName
    // ---------------------------------------------------------------

    @Test
    fun resolveClassName_expands_leading_dot() {
        val pkg = "eu.kanade.tachiyomi.animeextension.en.hianime"
        val result = AniyomiExtensionLoader.resolveClassName(pkg, ".HiAnime")
        assertEquals("$pkg.HiAnime", result)
    }

    @Test
    fun resolveClassName_keeps_fully_qualified_name() {
        val fqn = "eu.kanade.tachiyomi.animeextension.en.hianime.HiAnime"
        val result = AniyomiExtensionLoader.resolveClassName("eu.kanade.foo", fqn)
        assertEquals(fqn, result)
    }

    @Test
    fun resolveClassName_expands_factory_leading_dot() {
        val pkg = "eu.kanade.tachiyomi.animeextension.all.jellyfin"
        assertEquals("$pkg.JellyfinFactory", AniyomiExtensionLoader.resolveClassName(pkg, ".JellyfinFactory"))
    }

    // ---------------------------------------------------------------
    // Version gate integration: libVersionOf + isLibVersionSupported
    // ---------------------------------------------------------------

    @Test
    fun version_gate_accepts_14_17() {
        // Jellyfin extension — versionName "14.17", libVersion 14.0
        val lib = AniyomiExtensionLoader.libVersionOf("14.17")
        assertTrue(AniyomiExtensionLoader.isLibVersionSupported(lib))
    }

    @Test
    fun version_gate_rejects_17_2() {
        // Hypothetical future extension — versionName "17.2", libVersion 17.0
        val lib = AniyomiExtensionLoader.libVersionOf("17.2")
        assertFalse(AniyomiExtensionLoader.isLibVersionSupported(lib))
    }

    // ---------------------------------------------------------------
    // Full DexClassLoad happy-path (deferred — needs Android runtime)
    // ---------------------------------------------------------------

    /**
     * The real load() call exercises [PackageManager.getPackageArchiveInfo] and
     * [DexClassLoader] which require a full Android runtime (not available in plain
     * JVM unit tests, even with Robolectric's limited PackageManager shadow).
     *
     * Validated on-device in Task 9 using the Jellyfin extension APK checked in at
     * android/app/src/test/resources/aniyomi/sample-anime-ext.apk (v14.17, lib 14.0).
     */
    @org.junit.Ignore("needs Android runtime for DexClassLoader + PackageManager — validated on-device in Task 9")
    @Test
    fun load_happy_path_real_apk() {
        // Intentionally empty — validated on-device.
    }
}
