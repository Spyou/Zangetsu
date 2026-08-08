package com.spyou.watch_app.mihon

import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for [MihonSourceManager].
 *
 * Uses a minimal fake [Source] because the interface has abstract members
 * that cannot be instantiated directly. The fake covers only the fields
 * MihonSourceManager cares about (id, name, lang). Mirrors
 * `AniyomiSourceManagerTest` in the sibling `aniyomi` package.
 */
class MihonSourceManagerTest {

    /** Minimal concrete [Source] for testing. */
    private class FakeSource(
        override val id: Long,
        override val name: String,
        override val lang: String = "en",
        override val supportsLatest: Boolean = false,
    ) : Source {
        override suspend fun getPopularManga(page: Int): MangasPage = MangasPage(emptyList(), false)
        override suspend fun getLatestUpdates(page: Int): MangasPage = MangasPage(emptyList(), false)
        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage =
            MangasPage(emptyList(), false)
        override suspend fun getMangaUpdate(
            manga: SManga,
            chapters: List<SChapter>,
            fetchDetails: Boolean,
            fetchChapters: Boolean,
        ): SMangaUpdate = SMangaUpdate(manga, chapters)
        override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    }

    private fun fakeExtension(pkg: String, vararg sources: Source) = MihonLoadedExtension(
        pkg = pkg,
        versionName = "1.4.52",
        versionCode = 1L,
        libVersion = 1.4,
        nsfw = false,
        sources = sources.toList(),
    )

    @Before
    fun clearManager() {
        // Reset singleton state between tests by draining via reflection rather
        // than adding a test-only API to production code.
        val sourcesField = MihonSourceManager::class.java.getDeclaredField("sources")
        sourcesField.isAccessible = true
        (sourcesField.get(MihonSourceManager) as java.util.LinkedHashMap<*, *>).clear()

        val extensionsField = MihonSourceManager::class.java.getDeclaredField("extensions")
        extensionsField.isAccessible = true
        (extensionsField.get(MihonSourceManager) as java.util.ArrayList<*>).clear()
    }

    @Test
    fun `register then get returns the source`() {
        val src = FakeSource(id = 42L, name = "TestSource")
        val ext = fakeExtension("com.example.test", src)

        MihonSourceManager.register(ext)

        assertNotNull(MihonSourceManager.get(42L))
        assertEquals("TestSource", MihonSourceManager.get(42L)?.name)
    }

    @Test
    fun `get returns null for unknown id`() {
        assertNull(MihonSourceManager.get(9999L))
    }

    @Test
    fun `installed reflects registered extension`() {
        val ext = fakeExtension("com.example.alpha", FakeSource(1L, "Alpha"))

        MihonSourceManager.register(ext)

        val installed = MihonSourceManager.installed()
        assertEquals(1, installed.size)
        assertEquals("com.example.alpha", installed.first().pkg)
    }

    @Test
    fun `re-registering same pkg replaces old sources`() {
        val oldSrc = FakeSource(id = 10L, name = "OldSource")
        val newSrc = FakeSource(id = 20L, name = "NewSource")

        MihonSourceManager.register(fakeExtension("com.example.replace", oldSrc))
        // Sanity check old source is present.
        assertNotNull(MihonSourceManager.get(10L))

        // Re-register with new source under the same package.
        MihonSourceManager.register(fakeExtension("com.example.replace", newSrc))

        // Old source must be evicted; new one must be present.
        assertNull(MihonSourceManager.get(10L))
        assertNotNull(MihonSourceManager.get(20L))
        // Still only one extension entry.
        assertEquals(1, MihonSourceManager.installed().size)
    }

    @Test
    fun `all returns every registered source`() {
        MihonSourceManager.register(
            fakeExtension(
                "com.example.multi",
                FakeSource(100L, "S1"),
                FakeSource(101L, "S2"),
            ),
        )

        val all = MihonSourceManager.all()
        assertEquals(2, all.size)
        assertTrue(all.any { it.id == 100L })
        assertTrue(all.any { it.id == 101L })
    }
}
