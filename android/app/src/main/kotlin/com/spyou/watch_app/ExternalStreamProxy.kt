package com.spyou.watch_app

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
 * Localhost HTTP proxy for handing header-gated streams to EXTERNAL players
 * (VLC, SPlayer, LeePlayer, …) that ignore intent header extras. The player is
 * given `http://127.0.0.1:<port>/s/<token>`; this proxy re-issues the real
 * request with the source's headers (Referer/Origin/Cookie/User-Agent) so the
 * CDN returns the stream instead of 403.
 *
 * Generic (unlike AniyomiVideoProxy, which uses an Aniyomi source client): it
 * forwards through a single plain OkHttpClient with the caller-supplied headers.
 * HLS playlists are rewritten (via the shared [HlsRewriter]) so segments, keys
 * and init segments also route back through the proxy.
 */
object ExternalStreamProxy {

    private data class Session(val url: String, val headers: Map<String, String>)

    private val sessions = ConcurrentHashMap<String, Session>()
    @Volatile private var server: NanoHTTPD? = null

    /** VOD manifests don't change → cache the rewritten text so seeking is snappy. */
    private val playlistCache = ConcurrentHashMap<String, String>()

    /** One streaming client: long read timeout, no overall cap, high per-host concurrency. */
    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .dispatcher(
                Dispatcher().apply {
                    maxRequests = 64
                    maxRequestsPerHost = 16
                },
            )
            .build()
    }

    @Synchronized
    private fun ensureStarted() {
        val s = server
        if (s != null && s.isAlive) return
        val newServer = object : NanoHTTPD("127.0.0.1", 0) {
            override fun serve(session: IHTTPSession): Response =
                this@ExternalStreamProxy.serve(session)
        }
        newServer.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
        server = newServer
    }

    /** Registers (url, headers) and returns http://127.0.0.1:<port>/s/<token>.
     *  HLS upstreams get a `.m3u8` suffix so the external player (and the intent
     *  mime detection) probes the top-level URL as HLS; segment/key URLs (non-
     *  m3u8 upstreams) get no suffix. serve() strips any extension. */
    fun proxyUrl(url: String, headers: Map<String, String>): String {
        ensureStarted()
        val token = UUID.randomUUID().toString().replace("-", "")
        sessions[token] = Session(url, headers)
        val suffix = if (url.contains("m3u8", ignoreCase = true)) ".m3u8" else ""
        return "http://127.0.0.1:${server!!.listeningPort}/s/$token$suffix"
    }

    private fun serve(httpSession: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        // Token is a dot-free UUID hex; strip the query and any `.m3u8` suffix.
        val token = httpSession.uri.removePrefix("/s/").substringBefore("?")
            .substringBefore(".")
        val ps = sessions[token]
            ?: return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.NOT_FOUND, "text/plain", "unknown token",
            )

        val urlPathEarly = ps.url.substringBefore("?")
        if (urlPathEarly.endsWith(".m3u8") || urlPathEarly.endsWith(".m3u")) {
            playlistCache[ps.url]?.let { cached ->
                return NanoHTTPD.newFixedLengthResponse(
                    NanoHTTPD.Response.Status.OK, "application/vnd.apple.mpegurl", cached,
                )
            }
        }

        val headersBuilder = Headers.Builder()
        ps.headers.forEach { (k, v) -> headersBuilder.add(k, v) }
        httpSession.headers["range"]?.let { headersBuilder.add("Range", it) }

        val request = Request.Builder().url(ps.url).headers(headersBuilder.build()).build()

        val upstream = try {
            client.newCall(request).execute()
        } catch (e: Exception) {
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR, "text/plain",
                e.message ?: "upstream request failed",
            )
        }

        val ct = upstream.header("Content-Type") ?: "application/octet-stream"
        val urlPath = ps.url.substringBefore("?")
        val isHlsByUrl = urlPath.endsWith(".m3u8") || urlPath.endsWith(".m3u")
        val isHlsByCt = ct.contains("mpegurl", ignoreCase = true)

        if (isHlsByUrl || isHlsByCt) {
            val text = upstream.body?.string() ?: ""
            val rewritten = HlsRewriter.rewrite(text, ps.url) { abs -> proxyUrl(abs, ps.headers) }
            upstream.close()
            playlistCache[ps.url] = rewritten
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK, "application/vnd.apple.mpegurl", rewritten,
            )
        }

        val bodyStream = upstream.body?.byteStream()
            ?: return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR, "text/plain", "empty body",
            )

        val peek = ByteArray(7)
        val n = bodyStream.read(peek)
        if (n > 0 && String(peek, 0, n, Charsets.US_ASCII).startsWith("#EXTM3U")) {
            val rest = bodyStream.readBytes()
            val fullText = String(peek, 0, n, Charsets.UTF_8) + String(rest, Charsets.UTF_8)
            val rewritten = HlsRewriter.rewrite(fullText, ps.url) { abs -> proxyUrl(abs, ps.headers) }
            upstream.close()
            playlistCache[ps.url] = rewritten
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK, "application/vnd.apple.mpegurl", rewritten,
            )
        }

        val restored = if (n > 0) {
            SequenceInputStream(ByteArrayInputStream(peek, 0, n), bodyStream)
        } else {
            bodyStream
        }
        val contentLength = upstream.header("Content-Length")?.toLongOrNull() ?: -1L
        val status = if (upstream.code == 206) NanoHTTPD.Response.Status.PARTIAL_CONTENT
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
}
