/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.spyou.watch_app.aniyomi

import com.spyou.watch_app.HlsRewriter
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import fi.iki.elonen.NanoHTTPD
import okhttp3.Dispatcher
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayInputStream
import java.io.SequenceInputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Localhost HTTP proxy that forwards every Aniyomi stream request (m3u8
 * manifest + TS segments + AES keys) through the **source's own
 * OkHttpClient**, which carries its Cloudflare session cookies, custom
 * UA, and Referer headers.
 *
 * mpv never touches the CDN directly — it only ever fetches from
 * `http://127.0.0.1:<port>/s/<token>`, and the proxy re-issues the real
 * request on its behalf.
 *
 * HLS playlists are rewritten on-the-fly: every segment URI (bare lines
 * and `URI="…"` attributes inside `#EXT-X-KEY / #EXT-X-MEDIA / #EXT-X-MAP`)
 * is resolved to an absolute URL and replaced with a fresh local proxy URL.
 * This means even encryption keys and init segments go through the proxy.
 *
 * Range requests (used by mpv for seeking in TS segments) are forwarded to
 * the upstream and 206 + Content-Range are propagated back.
 *
 * Usage:
 *   val localUrl = AniyomiVideoProxy.proxyUrl(sourceId, remoteUrl, headersMap)
 *   // pass localUrl to the player
 */
object AniyomiVideoProxy {

    // -------------------------------------------------------------------------
    // Internal session record
    // -------------------------------------------------------------------------

    private data class ProxySession(
        val sourceId: Long,
        val url: String,
        /** OkHttp header names/values from the originating Video object. */
        val headers: Map<String, String>,
    )

    /** Token → session. Grows during a playback session; acceptable. */
    private val sessions = ConcurrentHashMap<String, ProxySession>()

    @Volatile private var server: NanoHTTPD? = null

    /**
     * Per-source streaming client, derived from the source's own client so it
     * keeps the Cloudflare cookie jar + interceptors, but tuned for media
     * streaming: a long read timeout (slow CDN segments must not be cut off
     * like a normal API call would) and higher per-host concurrency (mpv bursts
     * many segment requests, especially right after a seek). Cached per source.
     */
    private val streamClients = ConcurrentHashMap<Long, OkHttpClient>()

    /** Original playlist URL → already-rewritten manifest text. Anime streams are
     *  VOD (the manifest never changes), so caching lets a seek re-use the
     *  manifest instantly instead of round-tripping the CDN through the source
     *  client on every scrub — the main cause of sluggish seeking vs native. */
    private val playlistCache = ConcurrentHashMap<String, String>()

    private fun streamClient(source: AnimeHttpSource, sourceId: Long): OkHttpClient =
        streamClients.getOrPut(sourceId) {
            source.client.newBuilder()
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .callTimeout(0, TimeUnit.MILLISECONDS) // no overall cap — streams
                .dispatcher(
                    Dispatcher().apply {
                        maxRequests = 64
                        maxRequestsPerHost = 16
                    },
                )
                .build()
        }

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /** Starts the NanoHTTPD server on an OS-assigned port; no-op if already alive. */
    @Synchronized
    fun ensureStarted() {
        val s = server
        if (s != null && s.isAlive) return
        val newServer = object : NanoHTTPD("127.0.0.1", 0) {
            override fun serve(session: IHTTPSession): Response =
                this@AniyomiVideoProxy.serve(session)
        }
        newServer.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
        server = newServer
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    /**
     * Registers ([sourceId], [url], [headers]) under a fresh opaque token and
     * returns a local proxy URL of the form `http://127.0.0.1:<port>/s/<token>`.
     *
     * The server is started lazily on the first call.
     */
    fun proxyUrl(sourceId: Long, url: String, headers: Map<String, String>): String {
        ensureStarted()
        val token = UUID.randomUUID().toString().replace("-", "")
        sessions[token] = ProxySession(sourceId, url, headers)
        return "http://127.0.0.1:${server!!.listeningPort}/s/$token"
    }

    // -------------------------------------------------------------------------
    // NanoHTTPD serve
    // -------------------------------------------------------------------------

    private fun serve(httpSession: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        // URI is /s/<token>; strip prefix, drop any query string.
        val token = httpSession.uri.removePrefix("/s/").substringBefore("?")
        val ps = sessions[token]
            ?: return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.NOT_FOUND, "text/plain", "unknown token"
            )

        val source = AniyomiSourceManager.get(ps.sourceId) as? AnimeHttpSource
            ?: return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR, "text/plain", "source unavailable"
            )

        // Fast path: a VOD manifest we already fetched + rewrote — serve it from
        // cache without touching the CDN again (makes seeking snappy).
        val urlPathEarly = ps.url.substringBefore("?")
        if (urlPathEarly.endsWith(".m3u8") || urlPathEarly.endsWith(".m3u")) {
            playlistCache[ps.url]?.let { cached ->
                return NanoHTTPD.newFixedLengthResponse(
                    NanoHTTPD.Response.Status.OK, "application/vnd.apple.mpegurl", cached,
                )
            }
        }

        // Build upstream request: use session headers, forward Range for seeking.
        val headersBuilder = Headers.Builder()
        ps.headers.forEach { (k, v) -> headersBuilder.add(k, v) }
        // NanoHTTPD lowercases incoming header names.
        httpSession.headers["range"]?.let { headersBuilder.add("Range", it) }

        val request = Request.Builder()
            .url(ps.url)
            .headers(headersBuilder.build())
            .build()

        val upstream = try {
            streamClient(source, ps.sourceId).newCall(request).execute()
        } catch (e: Exception) {
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR, "text/plain",
                e.message ?: "upstream request failed"
            )
        }

        val ct = upstream.header("Content-Type") ?: "application/octet-stream"

        // Detect HLS by content-type or URL path before touching the body.
        val urlPath = ps.url.substringBefore("?")
        val isHlsByUrl = urlPath.endsWith(".m3u8") || urlPath.endsWith(".m3u")
        val isHlsByCt = ct.contains("mpegurl", ignoreCase = true)

        if (isHlsByUrl || isHlsByCt) {
            val text = upstream.body?.string() ?: ""
            val rewritten = rewritePlaylist(text, ps.sourceId, ps.url, ps.headers)
            upstream.close()
            playlistCache[ps.url] = rewritten
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                "application/vnd.apple.mpegurl",
                rewritten,
            )
        }

        // Not obviously HLS — peek first 7 bytes to detect a bare #EXTM3U header.
        val bodyStream = upstream.body?.byteStream()
            ?: return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR, "text/plain", "empty body"
            )

        val peek = ByteArray(7)
        val n = bodyStream.read(peek)

        if (n > 0 && String(peek, 0, n, Charsets.US_ASCII).startsWith("#EXTM3U")) {
            val rest = bodyStream.readBytes()
            val fullText = String(peek, 0, n, Charsets.UTF_8) + String(rest, Charsets.UTF_8)
            val rewritten = rewritePlaylist(fullText, ps.sourceId, ps.url, ps.headers)
            upstream.close()
            playlistCache[ps.url] = rewritten
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                "application/vnd.apple.mpegurl",
                rewritten,
            )
        }

        // Binary pass-through — TS segment, AES key, MP4 init, etc.
        // Re-attach the peeked bytes via SequenceInputStream so nothing is lost.
        val restored = if (n > 0) {
            SequenceInputStream(ByteArrayInputStream(peek, 0, n), bodyStream)
        } else {
            bodyStream
        }

        val contentLength = upstream.header("Content-Length")?.toLongOrNull() ?: -1L
        val isPartial = upstream.code == 206
        val status = if (isPartial) NanoHTTPD.Response.Status.PARTIAL_CONTENT
                     else NanoHTTPD.Response.Status.OK

        val resp = if (contentLength >= 0) {
            NanoHTTPD.newFixedLengthResponse(status, ct, restored, contentLength)
        } else {
            NanoHTTPD.newChunkedResponse(status, ct, restored)
        }
        upstream.header("Content-Range")?.let { resp.addHeader("Content-Range", it) }
        resp.addHeader("Accept-Ranges", "bytes")
        return resp
    }

    // -------------------------------------------------------------------------
    // Playlist rewriting
    // -------------------------------------------------------------------------

    private fun rewritePlaylist(
        body: String,
        sourceId: Long,
        playlistUrl: String,
        headers: Map<String, String>,
    ): String = HlsRewriter.rewrite(body, playlistUrl) { absoluteUri ->
        proxyUrl(sourceId, absoluteUri, headers)
    }
}
