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

    // Per-instance: only carries a just-solved cookie into the retry within the
    // SAME intercept() call. Cross-CALL cookie reuse is the shared WebView cookie
    // store's job (WebkitCookieJar) + the persisted CfClearance.userAgent — not
    // this map. Kept per-instance on purpose: a static cookie map would wedge a
    // rotated/expired cf_clearance until app restart. The negative cache + per-host
    // lock ARE shared (companion) — with a fresh instance per request, a
    // per-instance backoff was lost, re-popping a 30s "verifying" on every click.
    private val cookieByHost = ConcurrentHashMap<String, String>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val host = request.url.host

        val response = chain.proceed(applySaved(request, host))
        if (!isCloudflareChallenge(response)) return response

        // During a provider search, NEVER pop the WebView solver (CloudStream
        // doesn't either): return the challenge unsolved so this source simply
        // yields no search hits. An already-cached clearance was applied above,
        // so CF sources solved earlier (on open/play) still search silently.
        if (com.spyou.watch_app.cloudstream.CfClearance.searchDepth.get() > 0) return response

        // The URL that actually produced the challenge — AFTER any redirects
        // (e.g. animepahe.com → animepahe.pw). The clearance cookie belongs to
        // THIS host, and we retry against THIS url so okhttp can't strip the
        // cookie across a cross-domain redirect.
        val finalUrl = response.request.url
        val finalHost = finalUrl.host
        synchronized(locks.getOrPut(finalHost) { Any() }) {
            if (!cookieByHost.containsKey(finalHost)) {
                // Negative cache: a host whose solve just failed isn't retried
                // (no solver popup) for ~30 min — just return the challenge.
                val until = failedUntil[finalHost]
                if (until != null && System.currentTimeMillis() < until) return response
                val solved = CfWebViewSolver.solve(finalUrl.toString())
                if (solved == null) {
                    failedUntil[finalHost] = System.currentTimeMillis() + 30 * 60 * 1000L
                    return response // give back the (unconsumed) challenge
                }
                failedUntil.remove(finalHost) // solved → clear any backoff
                cookieByHost[finalHost] = solved.cookie
                com.spyou.watch_app.cloudstream.CfClearance.userAgent = solved.userAgent
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
                com.spyou.watch_app.cloudstream.CfClearance.userAgent?.let { header("User-Agent", it) }
            }
            .build()
        return chain.proceed(retried)
    }

    /** Attach the harvested clearance cookie (+ the solving UA it's bound to) for
     *  [host], if this instance solved it in-call. Only touches requests we have a
     *  cookie for, so non-CF traffic keeps its own UA. */
    private fun applySaved(request: Request, host: String): Request {
        val cookie = cookieByHost[host] ?: return request
        val b = request.newBuilder()
        val existing = request.header("Cookie")
        b.header("Cookie", if (existing.isNullOrBlank()) cookie else "$existing; $cookie")
        com.spyou.watch_app.cloudstream.CfClearance.userAgent?.let { b.header("User-Agent", it) }
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

    companion object {
        // Shared across every CloudflareKiller instance (plugins make a fresh one
        // per request). host -> epoch-ms until which we won't re-attempt a solve:
        // a CF host we can't clear (e.g. an interactive challenge) would otherwise
        // pop a 30s "verifying" on EVERY request. The per-host lock is shared too so
        // concurrent requests for one host don't each launch a solver.
        private val failedUntil = ConcurrentHashMap<String, Long>()
        private val locks = ConcurrentHashMap<String, Any>()
    }
}

/** Loads a URL in a hidden WebView and waits for Cloudflare's `cf_clearance`
 * cookie. WebView work runs on the main thread; the (background) caller blocks
 * on a latch with a timeout. */
internal object CfWebViewSolver {
    data class Result(val cookie: String, val userAgent: String)

    fun solve(url: String): Result? {
        android.util.Log.i("CfSolver", "solve() host=${runCatching { android.net.Uri.parse(url).host }.getOrNull()}")
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
                if (ref.get() == null) main.postDelayed(this, 300)
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
                // Make the solver WebView's UA indistinguishable from desktop/mobile
                // Chrome. Stricter Cloudflare configs (e.g. gdflix) flag the WebView
                // tells — the "; wv" marker AND the WebView-only "Version/x.y" token,
                // which real Chrome never sends — and refuse to issue cf_clearance.
                // The cf_clearance is bound to whatever UA solved it, and we publish
                // that UA for the replay, so rewriting it here is self-consistent.
                wv.settings.userAgentString = wv.settings.userAgentString
                    .replace("; wv", "") // drop the WebView marker some CF checks flag
                    .replace(Regex("Version/\\d+\\.\\d+ "), "") // and the WebView-only token
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
                // Start polling early (CF often sets the cookie in well under a
                // second on a cached/managed challenge); a slow challenge just
                // keeps polling at 300ms up to the 30s latch, same as before.
                main.postDelayed(poll, 400)
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

    /// A clean app-bg screen with a small centered CHIP — "Verifying protected
    /// source…" with a spinner — laid over the solver WebView. The WebView must
    /// still render full-size behind it to satisfy Cloudflare's JS challenge, so
    /// we can't show only a chip over the live screen; but the chip tells the
    /// user exactly what's happening (a protected source being verified) instead
    /// of a bare spinner that reads like a freeze/bug. The chip only appears if
    /// the solve is slow — a quick/cached path tears down before it shows.
    private fun buildVerifyingOverlay(context: android.content.Context): android.view.View {
        val d = context.resources.displayMetrics.density
        fun dp(v: Int) = (v * d).toInt()

        val root = android.widget.FrameLayout(context)
        root.setBackgroundColor(0xFF0B0B0F.toInt()) // app background
        root.isClickable = true // swallow taps so they don't reach the WebView

        val chip = android.widget.LinearLayout(context)
        chip.orientation = android.widget.LinearLayout.HORIZONTAL
        chip.gravity = android.view.Gravity.CENTER_VERTICAL
        chip.setPadding(dp(16), dp(12), dp(20), dp(12))
        val bg = android.graphics.drawable.GradientDrawable()
        bg.cornerRadius = dp(26).toFloat()
        bg.setColor(0xFF17171C.toInt()) // surface
        bg.setStroke(dp(1), 0x22FFFFFF)
        chip.background = bg

        val spinner = android.widget.ProgressBar(context)
        spinner.indeterminateTintList =
            android.content.res.ColorStateList.valueOf(0xFFFF4D57.toInt()) // accent
        val slp = android.widget.LinearLayout.LayoutParams(dp(18), dp(18))
        slp.marginEnd = dp(12)
        chip.addView(spinner, slp)

        val label = android.widget.TextView(context)
        label.text = "Verifying protected source…"
        label.setTextColor(0xFFFFFFFF.toInt())
        label.textSize = 14f
        chip.addView(label)

        // Don't flash the chip for a quick solve — keep it a plain app-bg blank
        // and only reveal the chip if the challenge is still running after a
        // moment. Most cached/fast paths tear down before this fires.
        chip.visibility = android.view.View.INVISIBLE
        chip.postDelayed({ chip.visibility = android.view.View.VISIBLE }, 700)

        val lp = android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
            android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
        )
        lp.gravity = android.view.Gravity.CENTER
        root.addView(chip, lp)
        return root
    }
}
