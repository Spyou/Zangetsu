package eu.kanade.tachiyomi.network

import android.content.Context
import android.webkit.WebSettings
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

    init {
        // Adopt the DEVICE's real WebView User-Agent as the app's default.
        //
        // A cf_clearance cookie is tied to the browser identity that earned it,
        // and Cloudflare cross-checks the UA against signals the WebView sends
        // regardless (Sec-CH-UA client hints, TLS). Shipping a fixed
        // "Android 13; Pixel 7 … Chrome/125" string made those disagree: the
        // solver forces the WebView to claim Chrome 125 while its client hints
        // still say what it really is (a tester on Android 10 reported
        // Chrome/141), so the clearance is issued against an identity our
        // okhttp requests can't reproduce — the user passes the challenge and
        // is immediately blocked again. Taking the real UA makes the challenge
        // and the requests that follow it the same browser.
        //
        // `; wv` marks the UA as a WebView; upstream strips it so sources see a
        // normal Chrome, and the tester's Animiru UA confirms that convention.
        // Best-effort: this can throw while WebView is being updated, and the
        // hardcoded constant remains the fallback.
        if (deviceUserAgent == null) {
            deviceUserAgent = runCatching {
                WebSettings.getDefaultUserAgent(context)
                    .replace("; wv", "")
                    .takeIf { it.isNotBlank() }
            }.getOrNull()
        }
    }

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
        // Pin the User-Agent of clearance-carrying requests, at the wire.
        //
        // A network interceptor is the last thing before the socket, so it sees
        // (and fixes) the FINAL headers — an application interceptor can't. That
        // distinction is the whole point: on a blocked device the application
        // layer reported the UA as correct while the wire carried a different
        // one, because layers below it had rewritten the request. Anything that
        // must be true of what leaves the phone has to be enforced here.
        .addNetworkInterceptor { chain ->
            val original = chain.request()
            val cookieHeader = original.header("Cookie").orEmpty()
            val pinnedUa = solveUaFor(original.url.host)
            val req = if (
                pinnedUa != null &&
                cookieHeader.contains("cf_clearance") &&
                original.header("User-Agent") != pinnedUa
            ) {
                original.newBuilder().header("User-Agent", pinnedUa).build()
            } else {
                original
            }
            val res = chain.proceed(req)
            val cfServer = res.header("Server")?.contains("cloudflare", true) == true
            if (res.code in intArrayOf(403, 503) && cfServer) {
                val wireUa = req.header("User-Agent").orEmpty()
                val solveUa = (solveUaFor(req.url.host) ?: challengeUserAgent).orEmpty()
                val cookie = req.header("Cookie").orEmpty()
                fun tail(s: String) = if (s.length > 26) "…" + s.takeLast(26) else s
                android.util.Log.w(
                    "ZangetsuCF",
                    "refused at the wire: ${res.code} ${req.url.host} " +
                        "cf=${if (cookie.contains("cf_clearance")) "yes" else "NO"} " +
                        "ua=${if (wireUa == solveUa) "same" else "DIFF"} " +
                        "ray=${res.header("cf-ray")?.take(8) ?: "-"}\n" +
                        "wireUA=$wireUa\nsolveUA=$solveUa\ncookie=${tail(cookie)}",
                )
            }
            res
        }
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

    /** The instance overload the interceptors above are wired to — it must
     *  resolve to the SAME string as the companion one, or okhttp would send a
     *  different UA than the Cloudflare solve used. */
    fun defaultUserAgentProvider(): String = Companion.defaultUserAgentProvider()

    companion object {
        /** Fallback only — used until [deviceUserAgent] is known, and on the
         *  rare device where WebView can't be queried at all. */
        private const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/125.0.0.0 Mobile Safari/537.36"

        /** The device's own WebView UA (`; wv` stripped), filled in by the
         *  NetworkHelper constructor. Null until then. */
        @Volatile
        var deviceUserAgent: String? = null

        fun defaultUserAgentProvider(): String = deviceUserAgent ?: DEFAULT_USER_AGENT

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

        /**
         * The UA a Cloudflare challenge was solved under, PER HOST.
         *
         * [challengeUserAgent] alone is a single global, and a browse fires
         * several requests at once (list, latest, covers) that need not carry
         * the same UA — whichever is challenged last wins, so the solve can run
         * under one request's UA while another goes out with a different one.
         * cf_clearance is bound to the UA that earned it, so Cloudflare refuses
         * the mismatch and the user is challenged again immediately. Measured on
         * a blocked device: cookie present on the wire, UA different.
         *
         * Keyed by host because that's the scope a clearance has.
         */
        private val solveUaByHost = java.util.concurrent.ConcurrentHashMap<String, String>()

        fun rememberSolveUa(host: String, ua: String?) {
            if (!ua.isNullOrBlank()) solveUaByHost[host] = ua
        }

        fun solveUaFor(host: String): String? = solveUaByHost[host]

        /**
         * When the visible solver last came away with a `cf_clearance`
         * (`System.currentTimeMillis()`, 0 = never).
         *
         * The Cloudflare interceptor clears cf_clearance before every re-solve.
         * That's right for a stale cookie and wrong for one the user just earned
         * by hand — deleting it means the next challenge re-prompts, and the
         * solve after that is deleted too, forever. This lets the interceptor
         * spot a fresh cookie and keep it.
         */
        @Volatile
        var lastSolveAtMs: Long = 0L
    }
}
