package com.spyou.watch_app.aniyomi

import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for [AniyomiSourceManager].
 *
 * Uses a minimal fake [AnimeSource] because the interface has abstract members
 * that cannot be instantiated directly. The fake covers only the fields
 * AniyomiSourceManager cares about (id, name, lang).
 */
class AniyomiSourceManagerTest {

    /** Minimal concrete [AnimeSource] for testing. */
    private class FakeAnimeSource(
        override val id: Long,
        override val name: String,
        override val lang: String = "en",
    ) : AnimeSource {
        override suspend fun getAnimeDetails(anime: SAnime): SAnime = anime
        override suspend fun getEpisodeList(anime: SAnime): List<SEpisode> = emptyList()
        override suspend fun getVideoList(episode: SEpisode): List<Video> = emptyList()
    }

    private fun fakeExtension(pkg: String, vararg sources: AnimeSource) = LoadedExtension(
        pkg = pkg,
        versionName = "14.1",
        versionCode = 1L,
        libVersion = 14.0,
        nsfw = false,
        sources = sources.toList(),
    )

    @Before
    fun clearManager() {
        // Reset singleton state between tests by re-registering nothing.
        // The manager uses mutable collections so we drain them via reflection
        // rather than adding a test-only API to production code.
        val sourcesField = AniyomiSourceManager::class.java.getDeclaredField("sources")
        sourcesField.isAccessible = true
        (sourcesField.get(AniyomiSourceManager) as java.util.LinkedHashMap<*, *>).clear()

        val extensionsField = AniyomiSourceManager::class.java.getDeclaredField("extensions")
        extensionsField.isAccessible = true
        (extensionsField.get(AniyomiSourceManager) as java.util.ArrayList<*>).clear()
    }

    @Test
    fun `register then get returns the source`() {
        val src = FakeAnimeSource(id = 42L, name = "TestSource")
        val ext = fakeExtension("com.example.test", src)

        AniyomiSourceManager.register(ext)

        assertNotNull(AniyomiSourceManager.get(42L))
        assertEquals("TestSource", AniyomiSourceManager.get(42L)?.name)
    }

    @Test
    fun `get returns null for unknown id`() {
        assertNull(AniyomiSourceManager.get(9999L))
    }

    @Test
    fun `installed reflects registered extension`() {
        val ext = fakeExtension("com.example.alpha", FakeAnimeSource(1L, "Alpha"))

        AniyomiSourceManager.register(ext)

        val installed = AniyomiSourceManager.installed()
        assertEquals(1, installed.size)
        assertEquals("com.example.alpha", installed.first().pkg)
    }

    @Test
    fun `re-registering same pkg replaces old sources`() {
        val oldSrc = FakeAnimeSource(id = 10L, name = "OldSource")
        val newSrc = FakeAnimeSource(id = 20L, name = "NewSource")

        AniyomiSourceManager.register(fakeExtension("com.example.replace", oldSrc))
        // Sanity check old source is present.
        assertNotNull(AniyomiSourceManager.get(10L))

        // Re-register with new source under the same package.
        AniyomiSourceManager.register(fakeExtension("com.example.replace", newSrc))

        // Old source must be evicted; new one must be present.
        assertNull(AniyomiSourceManager.get(10L))
        assertNotNull(AniyomiSourceManager.get(20L))
        // Still only one extension entry.
        assertEquals(1, AniyomiSourceManager.installed().size)
    }

    @Test
    fun `all returns every registered source`() {
        AniyomiSourceManager.register(
            fakeExtension(
                "com.example.multi",
                FakeAnimeSource(100L, "S1"),
                FakeAnimeSource(101L, "S2"),
            ),
        )

        val all = AniyomiSourceManager.all()
        assertEquals(2, all.size)
        assertTrue(all.any { it.id == 100L })
        assertTrue(all.any { it.id == 101L })
    }
}
