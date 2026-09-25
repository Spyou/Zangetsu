package com.spyou.watch_app

/**
 * The Intent contract between Dart and [PhonePlayerActivity].
 *
 * Deliberately its own file with its own keys. The TV player carries an
 * equivalent block inside its own companion object; keeping them separate is
 * what lets either player change its payload without breaking the other.
 *
 * Headers travel as a flat `String[]` of k,v,k,v rather than a Map extra: a
 * Map needs Serializable and is dropped silently by some OEM ROMs.
 */
object PhonePlayerIntent {
    const val EXTRA_URL = "url"
    const val EXTRA_HEADERS = "headers"          // flat String[]: k,v,k,v
    const val EXTRA_MIME = "mimeType"
    const val EXTRA_POSITION = "positionMs"      // start (resume) position
    const val EXTRA_TITLE = "title"
    const val EXTRA_EP_LABEL = "episodeLabel"
    const val EXTRA_EP_LABELS = "episodeLabels"
    const val EXTRA_EP_COUNT = "episodeCount"
    const val EXTRA_START_INDEX = "startIndex"
    const val EXTRA_SUB_URLS = "subUrls"
    const val EXTRA_SUB_LANGS = "subLangs"
    const val EXTRA_SUB_LABELS = "subLabels"
    const val EXTRA_SUB_FORMATS = "subFormats"
    const val EXTRA_SUB_DEFAULTS = "subDefaults"
    const val EXTRA_ACCENT = "accentColor"
    const val EXTRA_SW_DECODE = "softwareDecoding"
    const val EXTRA_SPEED = "defaultSpeed"
    const val EXTRA_SUB_SCALE = "subtitleScale"
    const val EXTRA_SUB_FG = "subtitleFgColor"
    const val EXTRA_SUB_BG_COLOR = "subtitleBgColor"
    const val EXTRA_SUB_EDGE_TYPE = "subtitleEdgeType"
    const val EXTRA_SUB_EDGE_COLOR = "subtitleEdgeColor"
    const val EXTRA_SUB_PREFERENCE = "subtitlePreference"
    const val EXTRA_SUB_FONT = "subtitleFontPath"
    const val EXTRA_AUTO_RESUME = "autoResume"
    const val EXTRA_KEEP_SCREEN_ON = "keepScreenOn"
    const val EXTRA_AUTOPLAY_NEXT = "autoplayNext"
    const val EXTRA_SEEK_SECONDS = "seekSeconds"
    const val EXTRA_BUF_MIN_MS = "minBufferMs"
    const val EXTRA_BUF_MAX_MS = "maxBufferMs"
    const val EXTRA_BUF_BYTES = "targetBufferBytes"
    const val EXTRA_BUF_BACK_MS = "backBufferMs"

    // Reported over the channel on close, not via setResult — the phone player
    // is started with startActivity, so there is no onActivityResult to hook.
    const val RESULT_POSITION = "positionMs"
    const val RESULT_DURATION = "durationMs"
    const val RESULT_EP_INDEX = "episodeIndex"
    const val RESULT_PLAYBACK_ERROR = "playbackError"

    fun headersToArray(m: Map<String, String>?): Array<String> {
        if (m.isNullOrEmpty()) return emptyArray()
        val out = ArrayList<String>(m.size * 2)
        for ((k, v) in m) { out.add(k); out.add(v) }
        return out.toTypedArray()
    }

    fun headersFromArray(a: Array<String>?): Map<String, String> {
        if (a == null || a.size < 2) return emptyMap()
        val out = LinkedHashMap<String, String>(a.size / 2)
        var i = 0
        // size - 1 so a truncated tail is dropped rather than thrown on.
        while (i < a.size - 1) { out[a[i]] = a[i + 1]; i += 2 }
        return out
    }
}
