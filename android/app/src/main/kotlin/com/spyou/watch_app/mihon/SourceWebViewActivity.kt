package com.spyou.watch_app.mihon

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Message
import android.os.SystemClock
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
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
import java.util.concurrent.ConcurrentHashMap
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

/**
 * When this screen was last closed, PER HOST.
 *
 * Read by the novel client's cookie jar to decide whether its own stored
 * cookie or the WebView's is the newer one. Pulled out of the Activity so it
 * can be tested without one, same as [shouldCloseOnPageFinished].
 *
 * Per host and not one shared stamp, because this screen serves every source
 * and both modes: a single stamp meant a sign-in on one source marked every
 * other host as freshly visited too, and a stale WebView cookie could then
 * shadow a cookie that had just come off a response for an unrelated site.
 *
 * The stamp is monotonic. The value it is compared against is written on a
 * response, so a wall clock stepped by an NTP correction in between can order
 * the two backwards.
 *
 * Hosts are matched exactly, the same key the novel jar stores under — a
 * sign-in on www.example.com does not cover a request to example.com. That
 * only costs the sign-in tiebreak on a source whose site and requests
 * disagree, which falls back to "the local copy wins", the safe default.
 */
internal object WebViewVisits {
    private val visitedAtMs = ConcurrentHashMap<String, Long>()

    fun record(host: String) {
        if (host.isNotBlank()) visitedAtMs[host] = SystemClock.elapsedRealtime()
    }

    /** Whether [host] has been visited since its cookies were stored. */
    fun isNewerThan(host: String, storedAtMs: Long): Boolean =
        (visitedAtMs[host] ?: 0L) > storedAtMs
}

class SourceWebViewActivity : AppCompatActivity() {

    private var solved = false
    private var stayOpen = false
    /** Empty until [onCreate] has a url — [onDestroy] runs even when it hasn't. */
    private var siteHost = ""
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
        siteHost = runCatching { Uri.parse(url).host }.getOrNull().orEmpty()

        val toolbar = Toolbar(this).apply {
            setBackgroundColor(if (stayOpen) BROWSER_BLUE else CLOUDFLARE_ORANGE)
            title = if (stayOpen) (screenTitle ?: "Browser") else "Solve Cloudflare"
            subtitle = siteHost
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
            webChromeClient = PopupToSameWindowClient()
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
        AndroidCookieJar().remove(url)
        CookieManager.getInstance().flush()
        // No count: remove() expires what it can see for this exact host, and a
        // cookie set on a parent domain survives that, so any number printed
        // here would claim more than actually went.
        Toast.makeText(this, "Cleared cookies for ${url.host}", Toast.LENGTH_SHORT).show()
        webView.loadUrl(targetUrl)
    }

    override fun onDestroy() {
        super.onDestroy()
        // Whatever the mode was, the WebView jar has just been through a real
        // browsing session and is the freshest view of THIS site's cookies.
        // Only this site's: every other host's cookies are exactly as old as
        // they were before the user opened this screen.
        WebViewVisits.record(siteHost)
        // Only the Cloudflare mode has a Dart call waiting on it. Resolving
        // from login mode could answer a solve started by a background browse
        // that nobody has actually completed.
        if (!stayOpen) {
            // Resolve the Dart solveCloudflare() call so the browse screen reloads —
            // whether the user solved it or just backed out (a reload is harmless).
            MihonBridge.finishCloudflareSolve()
            return
        }
        // The solve branch above flushes on its way out; a login never reaches
        // it, so without this the session cookie sits in Chromium's write
        // buffer and can be lost to a process death.
        CookieManager.getInstance().flush()
        // A sign-in page behind Cloudflare hands out a clearance on the way in.
        // Say so, or the next request clears it and re-solves for nothing.
        NetworkHelper.lastSolveAtMs = System.currentTimeMillis()
    }

    /**
     * Follows `window.open()` / `target="_blank"` in THIS WebView.
     *
     * `setDefaultSettings()` turns multiple windows on, and with nothing
     * handling them the navigation is dropped in silence — which is every
     * OAuth sign-in (Google, Discord, Patreon), the exact flow login mode
     * exists for. There is no second screen to give a popup, so the throwaway
     * WebView below exists only to catch the popup's first URL and hand it
     * back.
     */
    private inner class PopupToSameWindowClient : WebChromeClient() {
        override fun onCreateWindow(
            view: WebView,
            isDialog: Boolean,
            isUserGesture: Boolean,
            resultMsg: Message,
        ): Boolean {
            val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
            val relay = WebView(view.context)
            relay.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    relayView: WebView,
                    request: WebResourceRequest,
                ): Boolean {
                    view.loadUrl(request.url.toString())
                    // Not inside its own callback — destroying a WebView from
                    // one of its client calls tears down the frame that is
                    // still running.
                    relayView.post { relayView.destroy() }
                    return true
                }
            }
            transport.webView = relay
            resultMsg.sendToTarget()
            return true
        }
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_STAY_OPEN = "stay_open"
        const val EXTRA_TITLE = "title"

        /** Cloudflare mode's intent action — see [intentFor]. */
        const val ACTION_SOLVE = "com.spyou.watch_app.action.SOLVE_CLOUDFLARE"

        /** Login mode's intent action — see [intentFor]. */
        const val ACTION_LOGIN = "com.spyou.watch_app.action.SOURCE_LOGIN"

        /**
         * The launch intent for [url] in one of the two modes.
         *
         * The mode has to live in the ACTION, not just the extras: with
         * `FLAG_ACTIVITY_NEW_TASK` Android picks an existing task by
         * `Intent.filterEquals`, which ignores extras entirely. Same action
         * for both modes and a login screen left in the background gets
         * recycled for a Cloudflare solve — `onCreate` never runs, the screen
         * stays in login mode, and the Dart call waiting on the solve is never
         * answered.
         *
         * Login intents also carry the url as DATA so two sources get two
         * tasks. Solve intents deliberately do not: nothing waits on a login,
         * but a solve holds a single pending Dart result, and letting two
         * solver tasks exist at once means the older one's `onDestroy` answers
         * the newer one's call. Solve-to-solve therefore keeps reusing one
         * task, exactly as it always has.
         */
        fun intentFor(
            context: Context,
            url: String,
            stayOpen: Boolean,
            title: String? = null,
        ): Intent = Intent(context, SourceWebViewActivity::class.java).apply {
            action = if (stayOpen) ACTION_LOGIN else ACTION_SOLVE
            if (stayOpen) data = Uri.parse(url)
            putExtra(EXTRA_URL, url)
            putExtra(EXTRA_STAY_OPEN, stayOpen)
            putExtra(EXTRA_TITLE, title)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        private const val CLOUDFLARE_ORANGE = 0xFFF48120.toInt()
        private const val BROWSER_BLUE = 0xFF2B3350.toInt()
    }
}
