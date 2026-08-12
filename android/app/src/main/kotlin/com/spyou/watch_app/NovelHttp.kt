package com.spyou.watch_app

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
        return store[url.host]?.filter { it.expiresAt > now } ?: emptyList()
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

    /** Runs the call off the calling thread; returns (status, body, finalUrl). */
    suspend fun request(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
    ): Triple<Int, String, String> = withContext(Dispatchers.IO) {
        val verb = method.uppercase()
        val reqBody = when {
            body != null -> body.toRequestBody(null)
            // POST/PUT/PATCH require a body per OkHttp; GET/HEAD/DELETE must not.
            verb == "POST" || verb == "PUT" || verb == "PATCH" -> "".toRequestBody(null)
            else -> null
        }
        val requestBuilder = Request.Builder().url(url).method(verb, reqBody)
        headers.forEach { (k, v) -> requestBuilder.header(k, v) }

        client.newCall(requestBuilder.build()).execute().use { response ->
            val respBody = response.body?.string() ?: ""
            Triple(response.code, respBody, response.request.url.toString())
        }
    }
}
