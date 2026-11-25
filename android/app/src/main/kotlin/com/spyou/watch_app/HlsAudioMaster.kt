package com.spyou.watch_app

/**
 * Builds a tiny HLS master playlist that pairs a picture-only variant playlist
 * with its separate audio playlists.
 *
 * Some Aniyomi sources (Re:ANIME) hand back the video playlist on its own and the
 * audio as a list of extra tracks. Neither mpv nor ExoPlayer takes a track list
 * for a stream, but both already understand a master with `#EXT-X-MEDIA` audio,
 * so one master makes the audio play in both. Pure text, no I/O.
 */
object HlsAudioMaster {
    private val plainFile = Regex("""\.(mp4|mkv|webm|avi|mov|m4v|flv)$""", RegexOption.IGNORE_CASE)

    /** A progressive file can't be a variant of an HLS master, so it is left alone. */
    private fun isPlainFile(url: String) = plainFile.containsMatchIn(url.substringBefore('?'))

    /** [audio] is (url, name) pairs; the first one is the default. Null when there is none. */
    fun build(videoUrl: String, audio: List<Pair<String, String>>): String? {
        if (audio.isEmpty() || isPlainFile(videoUrl)) return null
        return buildString {
            append("#EXTM3U\n")
            audio.forEachIndexed { i, (url, name) ->
                val label = name.replace('"', '\'').ifBlank { "Audio ${i + 1}" }
                append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"").append(label)
                    .append("\",DEFAULT=").append(if (i == 0) "YES" else "NO")
                    .append(",AUTOSELECT=YES,URI=\"").append(url).append("\"\n")
            }
            // BANDWIDTH is required by the spec; the real rate is read from the media.
            append("#EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO=\"a\"\n")
            append(videoUrl).append('\n')
        }
    }
}
