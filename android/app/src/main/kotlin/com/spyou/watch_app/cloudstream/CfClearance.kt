package com.spyou.watch_app.cloudstream

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Shared Cloudflare-clearance state + a User-Agent interceptor.
 *
 * A `cf_clearance` cookie is bound to the EXACT User-Agent that solved the
 * challenge. The WebView solver runs with the device's Android WebView UA, but
 * NiceHttp's shared client sends its own (Windows Chrome) UA by default. So a
 * plain `app.get()` that carries `cf_clearance` (via [WebkitCookieJar]) but the
 * wrong UA is still rejected by Cloudflare.
 *
 * [userAgent] holds the UA the WebView solved with (set by CloudflareKiller's
 * WebView resolver). [Interceptor] is a NETWORK interceptor — it runs once per
 * hop INCLUDING redirects, after the cookie jar has attached cookies — so when a
 * request already carries `cf_clearance` it rewrites the UA to match. Scoped to
 * exactly those requests, so non-Cloudflare traffic is untouched.
 */
object CfClearance {
    // cf_clearance is bound to the EXACT UA that solved it. The cookie persists on
    // disk (WebView CookieManager) but the UA used to live only in memory — so
    // after an app restart the cached cookie was replayed with the WRONG (default)
    // UA and Cloudflare 403'd it → a full re-solve on the first play every launch.
    // Persist the UA too, so a restart reuses the clearance instead of re-verifying.
    private const val PREFS = "zangetsu_cf"
    private const val KEY_UA = "cf_solving_ua"

    @Volatile
    private var uaCache: String? = null

    var userAgent: String?
        get() {
            uaCache?.let { return it }
            val restored = runCatching {
                com.lagradost.cloudstream3.CloudStreamApp.getContext()
                    ?.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
                    ?.getString(KEY_UA, null)
            }.getOrNull()
            uaCache = restored
            return restored
        }
        set(value) {
            uaCache = value
            runCatching {
                com.lagradost.cloudstream3.CloudStreamApp.getContext()
                    ?.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
                    ?.edit()?.putString(KEY_UA, value)?.apply()
            }
        }

    /**
     * >0 while one or more provider SEARCHES are running. The WebView CF solver
     * is suppressed during search: it fans out across many sources, and must NOT
     * pop a "verifying" screen for each CF-gated one — CloudStream doesn't either.
     * A CF-gated source just returns no search hits until its clearance is solved
     * on open/play; after that the cached cookie makes its search work silently.
     */
    val searchDepth = java.util.concurrent.atomic.AtomicInteger(0)

    val interceptor: Interceptor = Interceptor { chain ->
        val req = chain.request()
        val ua = userAgent
        val cookie = req.header("Cookie")
        if (ua != null && cookie != null && cookie.contains("cf_clearance")) {
            chain.proceed(req.newBuilder().header("User-Agent", ua).build())
        } else {
            chain.proceed(req)
        }
    }
}
