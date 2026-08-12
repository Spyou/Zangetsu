package eu.kanade.tachiyomi.network

import android.content.Context
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import okhttp3.Cache
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Host-provided network service that Aniyomi anime extensions resolve through
 * `injectLazy()` and reach via [client] / [cloudflareClient].
 *
 * Upstream Aniyomi builds its own [OkHttpClient] here (Cloudflare interceptor,
 * DNS-over-HTTPS, cookie jar, cache). This host instead **wraps an already-built
 * client** — the app's single shared OkHttp (the CloudStream `baseClient`, which
 * already carries the WebView Cloudflare solver, cookie jar and optional DoH) — so
 * every extension shares one HTTP stack with the rest of the app. The graph that
 * hands this client in is stood up lazily in `AniyomiInjektModules` (never at boot).
 */
class NetworkHelper(
    private val context: Context,
    sharedClient: OkHttpClient,
) {

    /** Cookie store backed by the global WebView [android.webkit.CookieManager] —
     *  the same store the shared client's own jar writes to. Declared before
     *  [client] because the Cloudflare interceptor below reads/updates it. */
    val cookieJar = AndroidCookieJar()

    /**
     * Extension-facing client: the app's shared client (CloudStream's baseClient)
     * with an HTTP response cache installed. `newBuilder()` leaves the shared
     * client itself uncached, so the CloudStream streaming path is unchanged.
     *
     * Extensions default every GET/POST to `maxAge(10, MINUTES)` ([Requests]), but
     * that directive is a no-op unless a Cache backs it — upstream Tachiyomi/Mihon
     * installs one here and this port had dropped it, so every browse/detail/
     * chapter open re-hit the source. Restoring the cache serves repeat opens from
     * disk and eases source rate limits. Image/page byte fetches derive their own
     * cacheless client (`newCachelessCallWithProgress`), so only JSON lands here.
     */
    val client: OkHttpClient = sharedClient.newBuilder()
        // Mihon's default client must carry an UncaughtExceptionInterceptor FIRST
        // in the chain — some extensions (e.g. Asura Scans) assert its presence on
        // the DEFAULT client and otherwise throw "UncaughtExceptionInterceptor must
        // be present in default client", so browse/latest just fail. This is a
        // newBuilder copy of the shared client, so the CloudStream/anime client is
        // untouched; index 0 so it wraps everything below it.
        .apply { interceptors().add(0, UncaughtExceptionInterceptor()) }
        // Same story: extensions also assert a UserAgentInterceptor on the default
        // client ("UserAgentInterceptor must be present in default client"). It
        // just fills in a default User-Agent when a request has none.
        .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
        // 15 MB is plenty for JSON (browse/detail/chapter lists); LRU-evicted.
        .cache(Cache(File(context.cacheDir, "network_cache"), 15L * 1024 * 1024))
        // Read+write cookies through the global WebView CookieManager. Without
        // this the client inherits whatever jar the shared CloudStream client had
        // when this was built — which, depending on init order, can be none — so
        // the cf_clearance a Cloudflare solve stores in the WebView jar would
        // never be sent, and the source would stay blocked even after solving.
        .cookieJar(cookieJar)
        // Solve Cloudflare challenges (403/503 + `Server: cloudflare`) in a hidden
        // WebView, exactly as upstream Mihon does — without it, Cloudflare-gated
        // manga sources (e.g. Comix) 403 on every request. shouldIntercept() is
        // false for anything that isn't a Cloudflare challenge, so MangaDex and
        // other open sources pass straight through untouched. Added to the Mihon
        // client only — the shared CloudStream/anime client is not modified.
        .addInterceptor(
            CloudflareInterceptor(context, cookieJar, ::defaultUserAgentProvider),
        )
        .build()

    /**
     * @deprecated Since extension-lib 1.5 — the regular [client] handles Cloudflare.
     * Kept because older extensions still reference it.
     */
    @Deprecated("The regular client handles Cloudflare by default", ReplaceWith("client"))
    @Suppress("unused")
    val cloudflareClient: OkHttpClient = client

    /** Longer-timeout variant used by extensions for large media downloads.
     *  Cacheless — big media must not evict the JSON response cache (and was
     *  never cached before this). */
    val downloadClient: OkHttpClient = client.newBuilder()
        .cache(null)
        .callTimeout(30, TimeUnit.MINUTES)
        .build()

    fun defaultUserAgentProvider(): String = DEFAULT_USER_AGENT

    companion object {
        private const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/125.0.0.0 Mobile Safari/537.36"

        fun defaultUserAgentProvider(): String = DEFAULT_USER_AGENT

        /**
         * The User-Agent of the last request that hit a Cloudflare challenge.
         * The visible solver (MihonCloudflareActivity) reads this so it solves
         * with the SAME UA the source's okhttp requests actually send — a
         * cf_clearance cookie is bound to its UA, so a mismatch (source uses its
         * own UA, solver used the app default) makes Cloudflare reject the
         * solved cookie and re-challenge forever.
         */
        @Volatile
        var challengeUserAgent: String? = null
    }
}
