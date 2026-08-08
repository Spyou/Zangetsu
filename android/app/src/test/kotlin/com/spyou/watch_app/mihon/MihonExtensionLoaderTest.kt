package com.spyou.watch_app.mihon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure helper logic in [MihonExtensionLoader].
 *
 * These tests exercise [MihonExtensionLoader.libVersionOf],
 * [MihonExtensionLoader.resolveClassName], and
 * [MihonExtensionLoader.isLibVersionSupported] — all plain JVM logic with no
 * Android or DexClassLoader dependency. Mirrors
 * `AniyomiExtensionLoaderTest` in the sibling `aniyomi` package.
 *
 * The real-world values here ("1.4.52", "1.6.11") are sampled from the
 * keiyoushi extension repo — see the version-gate investigation in the M2
 * task report for how they were gathered.
 */
class MihonExtensionLoaderTest {

    // ---------------------------------------------------------------
    // libVersionOf
    // ---------------------------------------------------------------

    @Test
    fun libVersionOf_parses_real_lib_1_4_extension() {
        // "1.4.52" → substringBeforeLast('.') = "1.4" → 1.4
        assertEquals(1.4, MihonExtensionLoader.libVersionOf("1.4.52"), 0.0)
    }

    @Test
    fun libVersionOf_parses_real_lib_1_6_extension() {
        // "1.6.11" → substringBeforeLast('.') = "1.6" → 1.6
        assertEquals(1.6, MihonExtensionLoader.libVersionOf("1.6.11"), 0.0)
    }

    @Test(expected = NumberFormatException::class)
    fun libVersionOf_throws_on_non_numeric() {
        MihonExtensionLoader.libVersionOf("abc.def")
    }

    // ---------------------------------------------------------------
    // isLibVersionSupported — range gate 1.0 .. 2.0
    // ---------------------------------------------------------------

    @Test
    fun isLibVersionSupported_accepts_min_bound() {
        assertTrue(MihonExtensionLoader.isLibVersionSupported(1.0))
    }

    @Test
    fun isLibVersionSupported_accepts_max_bound() {
        assertTrue(MihonExtensionLoader.isLibVersionSupported(2.0))
    }

    @Test
    fun isLibVersionSupported_accepts_real_1_4() {
        assertTrue(MihonExtensionLoader.isLibVersionSupported(1.4))
    }

    @Test
    fun isLibVersionSupported_accepts_real_1_6() {
        assertTrue(MihonExtensionLoader.isLibVersionSupported(1.6))
    }

    @Test
    fun isLibVersionSupported_rejects_too_new() {
        // lib 2.1 — beyond MANGA_LIB_VERSION_MAX
        assertFalse(MihonExtensionLoader.isLibVersionSupported(2.1))
    }

    @Test
    fun isLibVersionSupported_rejects_too_old() {
        // lib 0.9 — below MANGA_LIB_VERSION_MIN
        assertFalse(MihonExtensionLoader.isLibVersionSupported(0.9))
    }

    // ---------------------------------------------------------------
    // resolveClassName
    // ---------------------------------------------------------------

    @Test
    fun resolveClassName_expands_leading_dot() {
        val pkg = "eu.kanade.tachiyomi.extension.en.mangadex"
        val result = MihonExtensionLoader.resolveClassName(pkg, ".MangaDex")
        assertEquals("$pkg.MangaDex", result)
    }

    @Test
    fun resolveClassName_keeps_fully_qualified_name() {
        val fqn = "eu.kanade.tachiyomi.extension.en.mangadex.MangaDex"
        val result = MihonExtensionLoader.resolveClassName("eu.kanade.foo", fqn)
        assertEquals(fqn, result)
    }

    @Test
    fun resolveClassName_expands_factory_leading_dot() {
        val pkg = "eu.kanade.tachiyomi.extension.all.madara"
        assertEquals("$pkg.MadaraFactory", MihonExtensionLoader.resolveClassName(pkg, ".MadaraFactory"))
    }

    // ---------------------------------------------------------------
    // Version gate integration: libVersionOf + isLibVersionSupported
    // ---------------------------------------------------------------

    @Test
    fun version_gate_accepts_1_4_52() {
        // Real keiyoushi extension — versionName "1.4.52", libVersion 1.4
        val lib = MihonExtensionLoader.libVersionOf("1.4.52")
        assertTrue(MihonExtensionLoader.isLibVersionSupported(lib))
    }

    @Test
    fun version_gate_accepts_1_6_11() {
        // Real keiyoushi extension — versionName "1.6.11", libVersion 1.6
        val lib = MihonExtensionLoader.libVersionOf("1.6.11")
        assertTrue(MihonExtensionLoader.isLibVersionSupported(lib))
    }

    @Test
    fun version_gate_rejects_2_1_0() {
        // Hypothetical future major-break extension — versionName "2.1.0", libVersion 2.1
        val lib = MihonExtensionLoader.libVersionOf("2.1.0")
        assertFalse(MihonExtensionLoader.isLibVersionSupported(lib))
    }

    // ---------------------------------------------------------------
    // Full DexClassLoad happy-path (deferred — needs Android runtime)
    // ---------------------------------------------------------------

    /**
     * The real load() call exercises [PackageManager.getPackageArchiveInfo] and
     * [DexClassLoader] which require a full Android runtime (not available in plain
     * JVM unit tests). Validated on-device once a real Mihon extension APK is
     * available, mirroring how the Aniyomi loader was verified on-device.
     */
    @org.junit.Ignore("needs Android runtime for DexClassLoader + PackageManager — validated on-device")
    @Test
    fun load_happy_path_real_apk() {
        // Intentionally empty — validated on-device.
    }
}
