package com.spyou.watch_app.mihon

import android.annotation.SuppressLint
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.Toolbar
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.util.system.setDefaultSettings
import eu.kanade.tachiyomi.util.system.setUserAgent

/**
 * Full-screen WebView that lets the user complete a Cloudflare challenge — the
 * interactive Turnstile that the headless solver ([eu.kanade.tachiyomi.network
 * .interceptor.CloudflareInterceptor]) can't pass on its own.
 *
 * The `cf_clearance` cookie the challenge issues lands in the global WebView
 * [CookieManager] — the same store [eu.kanade.tachiyomi.network.AndroidCookieJar]
 * (and therefore the Mihon OkHttp client) reads — so once it's solved, the
 * source's own requests succeed with no further work. This is the same approach
 * Mihon's WebViewActivity and AnymeX's CloudflareBypassWebView use.
 *
 * The WebView is configured with the SAME user agent (+ Sec-CH-UA metadata via
 * [setUserAgent]) and third-party-cookie setting ([setDefaultSettings]) as the
 * headless solver, so the clearance it issues is bound to a UA the OkHttp client
 * will resend.
 *
 * Launch with an [android.content.Intent] carrying [EXTRA_URL]. Auto-finishes
 * once `cf_clearance` appears for the host; the user can also close it from the
 * toolbar / system back.
 */
class MihonCloudflareActivity : AppCompatActivity() {

    private var solved = false
    private lateinit var targetUrl: String

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            finish()
            return
        }
        targetUrl = url
        val host = runCatching { Uri.parse(url).host }.getOrNull().orEmpty()

        val toolbar = Toolbar(this).apply {
            setBackgroundColor(CLOUDFLARE_ORANGE)
            title = "Solve Cloudflare"
            subtitle = host
            setTitleTextColor(Color.WHITE)
            setSubtitleTextColor(0xCCFFFFFF.toInt())
            navigationIcon = androidx.appcompat.content.res.AppCompatResources.getDrawable(
                this@MihonCloudflareActivity,
                androidx.appcompat.R.drawable.abc_ic_ab_back_material,
            )
            setNavigationOnClickListener { finish() }
        }

        CookieManager.getInstance().setAcceptCookie(true)

        val web = WebView(this).apply {
            setDefaultSettings()
            // Solve under the SAME UA the source's requests actually send (the UA
            // of the request that hit the challenge), not just the app default —
            // otherwise the cf_clearance is bound to a UA the source never sends
            // and Cloudflare rejects it. Falls back to the default when unknown.
            // Prefer THIS host's recorded UA: the global is whatever request was
            // challenged last, and a browse fires several at once, so it can
            // belong to a different host/request than the one being solved here.
            setUserAgent(
                NetworkHelper.solveUaFor(android.net.Uri.parse(targetUrl).host.orEmpty())
                    ?: NetworkHelper.challengeUserAgent
                    ?: NetworkHelper.defaultUserAgentProvider()
            )
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, pageUrl: String) {
                    maybeFinishIfSolved()
                }
            }
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(
                toolbar,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            addView(
                web,
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f),
            )
        }
        setContentView(root)

        web.loadUrl(url)
    }

    /** Closes the screen as soon as a fresh `cf_clearance` cookie is present. */
    private fun maybeFinishIfSolved() {
        if (solved) return
        val cookie = CookieManager.getInstance().getCookie(targetUrl).orEmpty()
        if (cookie.contains("cf_clearance")) {
            solved = true
            CookieManager.getInstance().flush()
            // Mark it fresh BEFORE the reload this finish() triggers, so the
            // interceptor keeps the cookie instead of clearing it and prompting
            // again — see NetworkHelper.lastSolveAtMs.
            NetworkHelper.lastSolveAtMs = System.currentTimeMillis()
            Toast.makeText(this, "Cloudflare passed", Toast.LENGTH_SHORT).show()
            setResult(RESULT_OK)
            finish()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Resolve the Dart solveCloudflare() call so the browse screen reloads —
        // whether the user solved it or just backed out (a reload is harmless).
        MihonBridge.finishCloudflareSolve()
    }

    companion object {
        const val EXTRA_URL = "url"
        private const val CLOUDFLARE_ORANGE = 0xFFF48120.toInt()
    }
}
