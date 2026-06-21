package com.lagradost.cloudstream3.network

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import com.lagradost.cloudstream3.CloudStreamApp
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Clean-room `CloudflareKiller` — the WebView-based Cloudflare solver that lets
 * CF-gated sources (AnimePahe, …) work, mirroring CloudStream's approach.
 *
 * When a response is the Cloudflare "Just a moment…" challenge, it loads the URL
 * in a hidden WebView so Cloudflare's JS runs, harvests the `cf_clearance`
 * cookie (+ the WebView's User-Agent), then replays the request with them.
 * Solved cookies are reused per-host until they expire (a later challenge
 * re-solves). Safe by design: for any NON-challenge response it returns the
 * response untouched, and every step is guarded — a failure just yields the
 * original (blocked) response, exactly like before.
 */
class CloudflareKiller : Interceptor {
    // Kept for binary compat with plugins that read it; we manage cookies below.
    val savedCookies: MutableMap<String, Map<String, String>> = mutableMapOf()

    private val cookieByHost = ConcurrentHashMap<String, String>()
    private val locks = ConcurrentHashMap<String, Any>()

    @Volatile
    private var userAgent: String? = null

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val host = request.url.host

        val response = chain.proceed(applySaved(request, host))
        if (!isCloudflareChallenge(response)) return response

        // The URL that actually produced the challenge — AFTER any redirects
        // (e.g. animepahe.com → animepahe.pw). The clearance cookie belongs to
        // THIS host, and we retry against THIS url so okhttp can't strip the
        // cookie across a cross-domain redirect.
        val finalUrl = response.request.url
        val finalHost = finalUrl.host
        synchronized(locks.getOrPut(finalHost) { Any() }) {
            if (!cookieByHost.containsKey(finalHost)) {
                val solved = CfWebViewSolver.solve(finalUrl.toString())
                    ?: return response // give back the (unconsumed) challenge
                cookieByHost[finalHost] = solved.cookie
                userAgent = solved.userAgent
            }
        }
        response.close()
        val cookie = cookieByHost[finalHost]
        val retried = request.newBuilder()
            .url(finalUrl)
            .apply {
                if (cookie != null) {
                    val existing = request.header("Cookie")
                    header("Cookie", if (existing.isNullOrBlank()) cookie else "$existing; $cookie")
                }
                userAgent?.let { header("User-Agent", it) }
            }
            .build()
        return chain.proceed(retried)
    }

    /** Attach the harvested clearance cookie + UA for [host], if we have them. */
    private fun applySaved(request: Request, host: String): Request {
        val cookie = cookieByHost[host]
        val ua = userAgent
        if (cookie == null && ua == null) return request
        val b = request.newBuilder()
        if (cookie != null) {
            val existing = request.header("Cookie")
            b.header("Cookie", if (existing.isNullOrBlank()) cookie else "$existing; $cookie")
        }
        if (ua != null) b.header("User-Agent", ua)
        return b.build()
    }

    /** True when [response] is a Cloudflare interstitial challenge page. Only
     * peeks HTML-ish bodies so JSON/media responses are cheap. */
    private fun isCloudflareChallenge(response: Response): Boolean {
        val server = response.header("Server").orEmpty().lowercase()
        val cfMitigated = response.header("cf-mitigated") != null
        val statusFlag = response.code in intArrayOf(403, 503, 429) &&
            server.contains("cloudflare")
        val ct = response.header("Content-Type").orEmpty().lowercase()
        val htmlish = ct.contains("text/html") || ct.isEmpty()
        if (!htmlish && !cfMitigated && !statusFlag) return false
        val body = try {
            response.peekBody(20_000L).string() // peek doesn't consume the body
        } catch (_: Exception) {
            return cfMitigated || statusFlag
        }
        return cfMitigated || statusFlag ||
            body.contains("Just a moment", ignoreCase = true) ||
            body.contains("challenge-platform") ||
            body.contains("challenges.cloudflare.com") ||
            body.contains("_cf_chl_opt") ||
            body.contains("cf-browser-verification")
    }
}

/** Loads a URL in a hidden WebView and waits for Cloudflare's `cf_clearance`
 * cookie. WebView work runs on the main thread; the (background) caller blocks
 * on a latch with a timeout. */
internal object CfWebViewSolver {
    data class Result(val cookie: String, val userAgent: String)

    fun solve(url: String): Result? {
        // Prefer the foreground Activity: the solver WebView must be attached to
        // a real window and rendered, or Cloudflare's JS challenge never runs.
        val activity = com.spyou.watch_app.MainActivity.current?.get()
        val context = activity ?: CloudStreamApp.getContext() ?: return null
        val latch = CountDownLatch(1)
        val ref = AtomicReference<Result?>()
        val main = Handler(Looper.getMainLooper())
        val webViewRef = AtomicReference<WebView?>()
        // The WebView must render full-size for Cloudflare's JS challenge to run,
        // but we don't want the user staring at the raw challenge/ad page. So we
        // wrap it in a container and lay a branded "Verifying…" overlay ON TOP —
        // CF's JS still executes underneath; the user just sees a clean screen.
        val containerRef = AtomicReference<android.view.View?>()

        fun captureIfReady() {
            CookieManager.getInstance().flush()
            val wv = webViewRef.get()
            val curUrl = wv?.url ?: url
            val cookieCur = CookieManager.getInstance().getCookie(curUrl)
            val cookieOrig = CookieManager.getInstance().getCookie(url)
            val cookie = listOfNotNull(cookieCur, cookieOrig)
                .firstOrNull { it.contains("cf_clearance") }
            if (cookie != null) {
                val ua = wv?.settings?.userAgentString ?: ""
                // Publish the solving UA so plain (interceptor-less) NiceHttp
                // requests carrying cf_clearance present the matching UA.
                if (ua.isNotEmpty()) com.spyou.watch_app.cloudstream.CfClearance.userAgent = ua
                if (ref.compareAndSet(null, Result(cookie, ua))) latch.countDown()
            }
        }

        val poll = object : Runnable {
            override fun run() {
                captureIfReady()
                if (ref.get() == null) main.postDelayed(this, 600)
            }
        }

        main.post {
            try {
                @SuppressLint("SetJavaScriptEnabled")
                val wv = WebView(context)
                webViewRef.set(wv)
                wv.settings.javaScriptEnabled = true
                wv.settings.domStorageEnabled = true
                wv.settings.databaseEnabled = true
                wv.settings.userAgentString = wv.settings.userAgentString
                    .replace("; wv", "") // drop the WebView marker some CF checks flag
                CookieManager.getInstance().setAcceptCookie(true)
                CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true)
                wv.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, finishedUrl: String?) {
                        captureIfReady()
                    }
                }
                // Attach the WebView to the window so it actually renders —
                // required for the challenge JS to execute. Removed after solve.
                if (activity != null) {
                    try {
                        // Must be full-size + genuinely VISIBLE for Cloudflare's
                        // JS challenge to run (occluded/1px/alpha-0 WebViews don't
                        // render → no solve), so the WebView stays full-size, but
                        // a branded opaque overlay sits on top so the user sees a
                        // clean "Verifying…" screen instead of the raw CF/ad page.
                        // Solved once per host, cached (~30min) → next loads skip it.
                        val mp = android.view.ViewGroup.LayoutParams.MATCH_PARENT
                        val container = android.widget.FrameLayout(context)
                        container.addView(
                            wv,
                            android.widget.FrameLayout.LayoutParams(mp, mp),
                        )
                        container.addView(
                            buildVerifyingOverlay(context),
                            android.widget.FrameLayout.LayoutParams(mp, mp),
                        )
                        containerRef.set(container)
                        activity.addContentView(
                            container,
                            android.view.ViewGroup.LayoutParams(mp, mp),
                        )
                    } catch (_: Throwable) {
                    }
                }
                wv.loadUrl(url)
                main.postDelayed(poll, 2000) // CF sets the cookie after its JS runs
            } catch (_: Throwable) {
                latch.countDown()
            }
        }

        val solved = try {
            latch.await(30, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            false
        }

        // Tear the WebView down on the main thread regardless of outcome.
        main.post {
            main.removeCallbacks(poll)
            try {
                // Remove the whole container (WebView + overlay) from the window,
                // then tear the WebView down.
                containerRef.get()?.let { c ->
                    (c.parent as? android.view.ViewGroup)?.removeView(c)
                }
                webViewRef.get()?.let { w ->
                    (w.parent as? android.view.ViewGroup)?.removeView(w)
                    w.stopLoading()
                    w.destroy()
                }
            } catch (_: Throwable) {
            }
        }
        return if (solved) ref.get() else null
    }

    /// An opaque, app-styled "Verifying…" screen shown over the solver WebView
    /// so the user never sees the raw Cloudflare challenge / parked page.
    private fun buildVerifyingOverlay(context: android.content.Context): android.view.View {
        val root = android.widget.FrameLayout(context)
        root.setBackgroundColor(0xFF0B0B0F.toInt()) // app background
        root.isClickable = true // swallow taps so they don't reach the WebView
        val col = android.widget.LinearLayout(context)
        col.orientation = android.widget.LinearLayout.VERTICAL
        col.gravity = android.view.Gravity.CENTER
        val spinner = android.widget.ProgressBar(context)
        spinner.indeterminateTintList =
            android.content.res.ColorStateList.valueOf(0xFFFF4D57.toInt()) // accent
        col.addView(spinner)
        val label = android.widget.TextView(context)
        label.text = "Verifying with the source…"
        label.setTextColor(0xFFFFFFFF.toInt())
        label.textSize = 15f
        label.gravity = android.view.Gravity.CENTER
        val pad = (16 * context.resources.displayMetrics.density).toInt()
        label.setPadding(pad, pad, pad, 0)
        col.addView(label)
        val sub = android.widget.TextView(context)
        sub.text = "This only takes a moment the first time."
        sub.setTextColor(0xFFA7A7B2.toInt())
        sub.textSize = 12f
        sub.gravity = android.view.Gravity.CENTER
        sub.setPadding(pad, pad / 2, pad, 0)
        col.addView(sub)
        val lp = android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
            android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
        )
        lp.gravity = android.view.Gravity.CENTER
        root.addView(col, lp)
        return root
    }
}
