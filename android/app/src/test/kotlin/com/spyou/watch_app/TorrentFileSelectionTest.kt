package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TorrentFileSelectionTest {
    private val sizes = longArrayOf(100, 900, 400, 800)
    private val names = arrayOf(
        "episode1.mkv",
        "episode2.mkv",
        "episode3.mkv",
        "episode4.mkv",
    )

    private fun select(requested: Int?): Int = TorrentFileSelection.select(
        sizes.size,
        requested,
        { sizes[it] },
        { names[it] },
    )

    @Test
    fun omittedIndex_keepsLargestVideo() {
        assertEquals(1, select(null))
    }

    @Test
    fun explicitIndexZero_winsOverLargerFiles() {
        assertEquals(0, select(0))
    }

    @Test
    fun explicitIndexThree_winsOverLargerFiles() {
        assertEquals(3, select(3))
    }

    @Test
    fun explicitSmallerEpisode_wins() {
        assertEquals(2, select(2))
    }

    @Test
    fun outOfRangeIndex_isRejected() {
        assertThrows(IllegalArgumentException::class.java) { select(-1) }
        assertThrows(IllegalArgumentException::class.java) { select(8) }
    }

    @Test
    fun nonVideoIndex_isRejected() {
        val files = arrayOf("episode.mkv", "notes.txt")
        val threw = runCatching {
            TorrentFileSelection.select(
                2,
                1,
                { 10L },
                { files[it] },
            )
        }.exceptionOrNull()
        assertEquals("not_a_video_file", threw?.message)
    }

    @Test
    fun noVideoFile_isRejected() {
        val threw = runCatching {
            TorrentFileSelection.select(
                1,
                null,
                { 10L },
                { "readme.txt" },
            )
        }.exceptionOrNull()
        assertEquals("no_video_in_torrent", threw?.message)
    }
}
