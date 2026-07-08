package com.spyou.watch_app

/**
 * Pure URI-rewriting engine for HLS playlists. Shared by the Aniyomi video
 * proxy and the external-player stream proxy.
 *
 * Processes every line in [body]:
 * - Blank lines: passed through.
 * - `#EXT-X-KEY:`, `#EXT-X-MEDIA:`, `#EXT-X-MAP:` tags: the `URI="…"` attribute
 *   value is resolved to an absolute URL and replaced with [resolveUri]'s result.
 * - Other `#…` lines: passed through unchanged.
 * - All other lines (segment / variant URIs): resolved to an absolute URL and
 *   replaced with [resolveUri]'s result.
 *
 * Relative URIs resolve against the directory of [playlistUrl]; root-relative
 * (`/path`) against its scheme+host; protocol-relative (`//host/…`) get `https:`;
 * already-absolute URIs are forwarded as-is. Contains no I/O — directly testable.
 */
object HlsRewriter {
    fun rewrite(
        body: String,
        playlistUrl: String,
        resolveUri: (String) -> String,
    ): String {
        val stripped = playlistUrl.substringBefore("?")
        val baseDir = stripped.let { s ->
            val idx = s.lastIndexOf('/')
            if (idx >= 0) s.substring(0, idx + 1) else "$s/"
        }
        val schemeHost = playlistUrl.let { u ->
            val s = u.indexOf("://")
            if (s < 0) return@let ""
            val slash = u.indexOf('/', s + 3)
            if (slash < 0) u else u.substring(0, slash)
        }

        fun toAbsolute(uri: String): String = when {
            uri.startsWith("http://") || uri.startsWith("https://") -> uri
            uri.startsWith("//") -> "https:$uri"
            uri.startsWith("/") -> "$schemeHost$uri"
            else -> "$baseDir$uri"
        }

        val uriTagPrefix = Regex("""^#EXT-X-(KEY|MEDIA|MAP):""")
        val uriAttr = Regex("""URI="([^"]+)"""")

        return body.lines().joinToString("\n") { line ->
            when {
                line.isBlank() -> line
                uriTagPrefix.containsMatchIn(line) -> {
                    uriAttr.replace(line) { m ->
                        val abs = toAbsolute(m.groupValues[1])
                        """URI="${resolveUri(abs)}""""
                    }
                }
                line.startsWith("#") -> line
                else -> resolveUri(toAbsolute(line.trim()))
            }
        }
    }
}
