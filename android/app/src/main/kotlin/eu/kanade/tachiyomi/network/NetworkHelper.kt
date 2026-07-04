package eu.kanade.tachiyomi.network

import android.content.Context
import okhttp3.OkHttpClient
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
    @Suppress("unused") private val context: Context,
    val client: OkHttpClient,
) {

    /** Cookie store backed by the global WebView [android.webkit.CookieManager] —
     *  the same store the shared client's own jar writes to. */
    val cookieJar = AndroidCookieJar()

    /**
     * @deprecated Since extension-lib 1.5 — the regular [client] handles Cloudflare.
     * Kept because older extensions still reference it.
     */
    @Deprecated("The regular client handles Cloudflare by default", ReplaceWith("client"))
    @Suppress("unused")
    val cloudflareClient: OkHttpClient = client

    /** Longer-timeout variant used by extensions for large media downloads. */
    val downloadClient: OkHttpClient = client.newBuilder()
        .callTimeout(30, TimeUnit.MINUTES)
        .build()

    fun defaultUserAgentProvider(): String = DEFAULT_USER_AGENT

    companion object {
        private const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/125.0.0.0 Mobile Safari/537.36"

        fun defaultUserAgentProvider(): String = DEFAULT_USER_AGENT
    }
}
