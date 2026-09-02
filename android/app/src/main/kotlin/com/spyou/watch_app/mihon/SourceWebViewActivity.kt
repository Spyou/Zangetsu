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
import eu.kanade.tachiyomi.network.AndroidCookieJar
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.util.system.setDefaultSettings
import eu.kanade.tachiyomi.util.system.setUserAgent
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * The app's one visible WebView, in two modes.
 *
 * Cloudflare mode (the default) loads a challenged URL and dismisses itself the
 * moment a `cf_clearance` cookie appears. Login mode ([EXTRA_STAY_OPEN]) leaves
 * the screen to the user, so a source that gates content behind a sign-in can
 * be signed in to; it also offers a per-site cookie clear.
 *
 * The name said Mihon because Mihon needed it first, but it is launched from
 * the shared `eu.kanade.tachiyomi.network` interceptor and serves Aniyomi too,
 * and the cookies it earns are read by the novel client as well.
 */

/**
 * Whether `onPageFinished` should dismiss the screen.
 *
 * Pulled out of the Activity so it can be tested without one. The Cloudflare
 * answer here is the app's oldest working behaviour — see
 * SourceWebViewDecisionTest before changing any of it.
 */
internal fun shouldCloseOnPageFinished(
    stayOpen: Boolean,
    alreadySolved: Boolean,
    cookie: String,
): Boolean {
    // Login mode is the user's screen to close. A challenge passing on the way
    // to a sign-in page is not a reason to take it away from them.
    if (stayOpen) return false
    if (alreadySolved) return false
    return cookie.contains("cf_clearance")
}

class SourceWebViewActivity : AppCompatActivity() {

    private var solved = false
    private var stayOpen = false
    private lateinit var targetUrl: String
    private lateinit var webView: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            finish()
            return
        }
        targetUrl = url
        stayOpen = intent.getBooleanExtra(EXTRA_STAY_OPEN, false)
        val screenTitle = intent.getStringExtra(EXTRA_TITLE)
        val host = runCatching { Uri.parse(url).host }.getOrNull().orEmpty()

        val toolbar = Toolbar(this).apply {
            setBackgroundColor(if (stayOpen) BROWSER_BLUE else CLOUDFLARE_ORANGE)
            title = if (stayOpen) (screenTitle ?: "Browser") else "Solve Cloudflare"
            subtitle = host
            setTitleTextColor(Color.WHITE)
            setSubtitleTextColor(0xCCFFFFFF.toInt())
            navigationIcon = androidx.appcompat.content.res.AppCompatResources.getDrawable(
                this@SourceWebViewActivity,
                androidx.appcompat.R.drawable.abc_ic_ab_back_material,
            )
            setNavigationOnClickListener { finish() }
            if (stayOpen) {
                menu.add("Clear cookies").setOnMenuItemClickListener {
                    clearCookiesForSite()
                    true
                }
            }
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
        webView = web

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
        val cookie = CookieManager.getInstance().getCookie(targetUrl).orEmpty()
        if (!shouldCloseOnPageFinished(stayOpen = stayOpen, alreadySolved = solved, cookie = cookie)) {
            return
        }
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

    /**
     * Expires this host's cookies and reloads — the escape hatch for a
     * half-finished login or a session the site has stopped honouring.
     *
     * Scoped to the one host: a blanket clear would sign the user out of every
     * other source and throw away Cloudflare clearances that took a captcha to
     * earn.
     */
    private fun clearCookiesForSite() {
        val url = targetUrl.toHttpUrlOrNull()
        if (url == null) {
            Toast.makeText(this, "Nothing to clear", Toast.LENGTH_SHORT).show()
            return
        }
        val cleared = AndroidCookieJar().remove(url)
        CookieManager.getInstance().flush()
        Toast.makeText(this, "Cleared $cleared cookies", Toast.LENGTH_SHORT).show()
        webView.loadUrl(targetUrl)
    }

    override fun onDestroy() {
        super.onDestroy()
        // Only the Cloudflare mode has a Dart call waiting on it. Resolving
        // from login mode could answer a solve started by a background browse
        // that nobody has actually completed.
        if (!stayOpen) {
            // Resolve the Dart solveCloudflare() call so the browse screen reloads —
            // whether the user solved it or just backed out (a reload is harmless).
            MihonBridge.finishCloudflareSolve()
        }
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_STAY_OPEN = "stay_open"
        const val EXTRA_TITLE = "title"
        private const val CLOUDFLARE_ORANGE = 0xFFF48120.toInt()
        private const val BROWSER_BLUE = 0xFF2B3350.toInt()
    }
}
