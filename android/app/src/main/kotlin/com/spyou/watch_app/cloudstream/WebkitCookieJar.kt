package com.spyou.watch_app.cloudstream

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Bridges OkHttp's cookie storage to Android's WebView [CookieManager].
 *
 * NiceHttp's default client ships with NO cookie jar (`CookieJar.NO_COOKIES`),
 * so cookies are never persisted or re-sent across `app.get()` calls. That
 * breaks providers that solve a Cloudflare challenge on ONE request (via the
 * [CloudflareKiller] interceptor + WebView) and then make further requests
 * WITHOUT the interceptor — e.g. AnimePahe fetches its episode list with a
 * plain `app.get(".../api?m=release")` and relies on the `cf_clearance` cookie
 * already being in a shared jar (exactly how upstream CloudStream behaves).
 *
 * The WebView solver writes `cf_clearance` into the global [CookieManager]; this
 * jar reads from there so every NiceHttp request for that domain carries it.
 * It's purely additive — it only sends cookies a browser would already send,
 * and any failure degrades to "no cookies" rather than throwing.
 */
class WebkitCookieJar : CookieJar {
    private val cm: CookieManager
        get() = CookieManager.getInstance()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        runCatching {
            val u = url.toString()
            cookies.forEach { cm.setCookie(u, it.toString()) }
            cm.flush()
        }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> = runCatching {
        val raw = cm.getCookie(url.toString()) ?: return emptyList()
        raw.split(";").mapNotNull { pair -> Cookie.parse(url, pair.trim()) }
    }.getOrDefault(emptyList())
}
