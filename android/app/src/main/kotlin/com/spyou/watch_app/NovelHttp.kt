package com.spyou.watch_app

import android.webkit.CookieManager
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * In-memory cookie jar keyed by host, so a Cloudflare clearance cookie set on
 * one request is re-sent on the next within this process. Not persisted
 * across app restarts — ponytail: fine for now, a CF cookie is short-lived
 * and the plugin re-issues requests every session anyway.
 */
private class InMemoryCookieJar : CookieJar {
    private val store = ConcurrentHashMap<String, List<Cookie>>()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        if (cookies.isNotEmpty()) store[url.host] = cookies
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        val own = store[url.host]?.filter { it.expiresAt > now } ?: emptyList()
        return own + webViewCookies(url, own)
    }

    /**
     * Cookies the WebView holds for this host, merged in READ-ONLY.
     *
     * This is what carries a `cf_clearance` earned in the visible solver into
     * the novel client. It only works alongside [NovelHttp.deviceUserAgent]:
     * a clearance is bound to the User-Agent that earned it, so the WebView's
     * cookie is rejected unless our requests present the same UA. Removing
     * either half puts the source straight back to blocked — verified by
     * removing this and watching Novel Updates fail again.
     *
     * Deliberately one-way: nothing received here is written back to the
     * WebView jar, so the novel lane still cannot disturb CloudStream or Mihon
     * cookie state. Locally-held names win, so a fresh response cookie is never
     * shadowed by a stale WebView one.
     */
    private fun webViewCookies(url: HttpUrl, own: List<Cookie>): List<Cookie> {
        val raw = runCatching {
            CookieManager.getInstance().getCookie(url.toString())
        }.getOrNull() ?: return emptyList()
        if (raw.isBlank()) return emptyList()
        val have = own.map { it.name }.toSet()
        return raw.split(';').mapNotNull { pair ->
            val t = pair.trim()
            val eq = t.indexOf('=')
            if (eq <= 0) return@mapNotNull null
            val name = t.substring(0, eq)
            if (name in have) return@mapNotNull null
            runCatching {
                Cookie.Builder().name(name).value(t.substring(eq + 1))
                    .domain(url.host).build()
            }.getOrNull()
        }
    }
}

/**
 * Dedicated OkHttp fetch used ONLY for the LNReader novel-plugin path.
 * The reason this exists at all: a plain OkHttpClient on Android rides the
 * platform TLS stack (Conscrypt/BoringSSL), which produces a Chrome-like
 * JA3/TLS fingerprint — the same one the real LNReader app (React Native ->
 * OkHttp) presents. dart:io/Dio's fingerprint is what gets 403'd by
 * Cloudflare's bot-fight on sources like webnovel.com, no header block fixes
 * that. So do NOT install a custom SSLSocketFactory/TrustManager here — a
 * bespoke one would throw away the exact stack this file exists to use.
 */
object NovelHttp {
    /**
     * The device's real WebView User-Agent, set once from MainActivity.
     *
     * Dart sends a fixed desktop-Chrome string, and Cloudflare cross-checks the
     * UA against the TLS fingerprint and client hints — a Windows Chrome UA
     * arriving on an Android BoringSSL handshake is an obvious mismatch, and
     * novelupdates.com answers it with `cf-mitigated: challenge`. The real
     * LNReader app sends the device's own UA (its persisted getUserAgent), so
     * its UA and its TLS agree. NetworkHelper already does exactly this for the
     * Mihon lane, for the same reason.
     *
     * Null until set (tests, or before MainActivity runs) — the caller's own
     * header is used then, which is the behaviour that existed before.
     */
    @Volatile
    var deviceUserAgent: String? = null
    // Built on first use, not at app boot — stays dormant unless a novel
    // source actually needs it.
    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .followRedirects(true)
            .followSslRedirects(true)
            .cookieJar(InMemoryCookieJar())
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /** What a novel fetch answers with. Response headers are carried because
     *  some plugins read a page count / content-type / token off them and
     *  throw without it. */
    data class Response(
        val status: Int,
        val body: String,
        val url: String,
        val headers: Map<String, String>,
        /** Cloudflare wants a human to pass a challenge. Dart surfaces this as
         *  the "Solve Cloudflare" prompt — without it a fresh install can never
         *  mint the cf_clearance that [InMemoryCookieJar.webViewCookies] then
         *  carries, and the source stays blocked forever. */
        val cloudflare: Boolean,
    )

    /** `cf-mitigated: challenge` is Cloudflare saying so outright; 403/503 from
     *  a cloudflare server is the older signal. The cloudflare server header is
     *  required either way, so a plain 403 from the site is never mistaken. */
    private fun looksLikeChallenge(status: Int, headers: okhttp3.Headers): Boolean {
        val server = headers["server"]?.lowercase().orEmpty()
        if (!server.contains("cloudflare")) return false
        if (headers["cf-mitigated"]?.lowercase() == "challenge") return true
        return status == 403 || status == 503
    }


    /** Runs the call off the calling thread. */
    suspend fun request(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
    ): Response = withContext(Dispatchers.IO) {
        val verb = method.uppercase()
        val reqBody = when {
            body != null -> body.toRequestBody(null)
            // POST/PUT/PATCH require a body per OkHttp; GET/HEAD/DELETE must not.
            verb == "POST" || verb == "PUT" || verb == "PATCH" -> "".toRequestBody(null)
            else -> null
        }
        val requestBuilder = Request.Builder().url(url).method(verb, reqBody)
        headers.forEach { (k, v) -> requestBuilder.header(k, v) }
        // Override the caller's UA with the device's own, so it matches the TLS
        // stack this client rides. A plugin that deliberately sets its own UA is
        // left alone — only the generic default is replaced.
        deviceUserAgent?.let { ua ->
            val sent = headers.entries
                .firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }?.value
            if (sent == null || sent.contains("Windows NT")) {
                requestBuilder.header("User-Agent", ua)
            }
        }

        client.newCall(requestBuilder.build()).execute().use { response ->
            val respBody = response.body?.string() ?: ""
            // A header can legitimately repeat (Set-Cookie); join the way HTTP
            // itself does so nothing is silently dropped.
            val respHeaders = response.headers.names().associateWith { name ->
                response.headers.values(name).joinToString(", ")
            }
            Response(
                response.code,
                respBody,
                response.request.url.toString(),
                respHeaders,
                looksLikeChallenge(response.code, response.headers),
            )
        }
    }
}
