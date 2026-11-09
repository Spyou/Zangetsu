package com.spyou.watch_app

// Use the requested video, or the largest video when no index is supplied.
internal object TorrentFileSelection {
    val VIDEO_EXTENSIONS = listOf(
        ".mp4", ".mkv", ".avi", ".webm", ".mov", ".m4v", ".ts", ".flv",
    )

    fun select(
        fileCount: Int,
        requestedIndex: Int?,
        sizeAt: (Int) -> Long,
        nameAt: (Int) -> String,
    ): Int {
        if (requestedIndex != null) {
            require(requestedIndex in 0 until fileCount) { "bad_file_index" }
            require(isVideo(nameAt(requestedIndex))) { "not_a_video_file" }
            return requestedIndex
        }
        var best = -1
        var bestSize = -1L
        for (i in 0 until fileCount) {
            if (isVideo(nameAt(i)) && sizeAt(i) > bestSize) {
                best = i
                bestSize = sizeAt(i)
            }
        }
        check(best >= 0) { "no_video_in_torrent" }
        return best
    }

    private fun isVideo(name: String): Boolean {
        val lower = name.lowercase()
        return VIDEO_EXTENSIONS.any { lower.endsWith(it) }
    }
}
