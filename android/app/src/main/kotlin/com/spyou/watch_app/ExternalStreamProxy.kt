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
 * LAN HTTP proxy for handing header-gated streams to EXTERNAL players
 * (VLC, SPlayer, LeePlayer, Web Video Cast, …) that ignore intent header extras.
 * The player is given `http://<lan-ip>:<port>/s/<token>` (loopback if the phone
 * has no usable LAN address); this proxy re-issues the real request with the
 * source's headers (Referer/Origin/Cookie/User-Agent) so the CDN returns the
 * stream instead of 403.
 *
 * Bound on all interfaces so a Cast receiver (Chromecast, NVIDIA Shield) can
 * fetch the URL a cast app handed it. Playlists are stored with a 127.0.0.1
 * host and rewritten to the incoming `Host` on serve — otherwise the receiver
 * would try to pull segments from itself. CORS is added because the Cast
 * default receiver fetches via XHR.
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
        // null hostname → all interfaces. Loopback-only binding made cast
        // apps (Web Video Cast → Shield/Chromecast) hand the receiver a URL
        // it could never reach.
        val newServer = object : NanoHTTPD(null, 0) {
            override fun serve(session: IHTTPSession): Response =
                withCors(this@ExternalStreamProxy.serve(session))
        }
        newServer.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
        server = newServer
    }

    /** Registers (url, headers) and returns a player-facing proxy URL.
     *  HLS upstreams get a `.m3u8` suffix so the external player (and the intent
     *  mime detection) probes the top-level URL as HLS; segment/key URLs (non-
     *  m3u8 upstreams) get no suffix. serve() strips any extension.
     *
     *  Advertises the phone's LAN IPv4 when one is available so a Cast
     *  receiver can fetch it; falls back to 127.0.0.1 for on-device players. */
    fun proxyUrl(url: String, headers: Map<String, String>): String {
        val loopback = register(url, headers)
        val ip = LanAddress.ipv4() ?: return loopback
        return loopback.replaceFirst("127.0.0.1", ip)
    }

    /** Canonical loopback form used inside rewritten playlists / the cache.
     *  [advertiseForRequest] swaps the host to match how the client reached us. */
    private fun register(url: String, headers: Map<String, String>): String {
        ensureStarted()
        val token = UUID.randomUUID().toString().replace("-", "")
        sessions[token] = Session(url, headers)
        val suffix = if (url.contains("m3u8", ignoreCase = true)) ".m3u8" else ""
        return "http://127.0.0.1:${server!!.listeningPort}/s/$token$suffix"
    }

    private fun withCors(resp: NanoHTTPD.Response): NanoHTTPD.Response {
        resp.addHeader("Access-Control-Allow-Origin", "*")
        resp.addHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        resp.addHeader("Access-Control-Allow-Headers", "Range, Origin, Accept, Content-Type")
        resp.addHeader(
            "Access-Control-Expose-Headers",
            "Content-Length, Content-Range, Accept-Ranges, Content-Type",
        )
        return resp
    }

    private fun advertiseForRequest(body: String, httpSession: NanoHTTPD.IHTTPSession): String {
        val host = httpSession.headers["host"] ?: return body
        val port = server?.listeningPort ?: return body
        return LanAddress.rewriteLoopbackHost(body, port, host)
    }

    private fun serve(httpSession: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        if (httpSession.method == NanoHTTPD.Method.OPTIONS) {
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK, "text/plain", "",
            )
        }
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
                    NanoHTTPD.Response.Status.OK, "application/vnd.apple.mpegurl",
                    advertiseForRequest(cached, httpSession),
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
            val rewritten = HlsRewriter.rewrite(text, ps.url) { abs -> register(abs, ps.headers) }
            upstream.close()
            playlistCache[ps.url] = rewritten
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK, "application/vnd.apple.mpegurl",
                advertiseForRequest(rewritten, httpSession),
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
            val rewritten = HlsRewriter.rewrite(fullText, ps.url) { abs -> register(abs, ps.headers) }
            upstream.close()
            playlistCache[ps.url] = rewritten
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK, "application/vnd.apple.mpegurl",
                advertiseForRequest(rewritten, httpSession),
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
