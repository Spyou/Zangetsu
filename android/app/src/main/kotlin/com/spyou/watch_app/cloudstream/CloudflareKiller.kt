package com.lagradost.cloudstream3.network

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Clean-room stand-in for CloudStream's `CloudflareKiller`.
 *
 * The real one uses a WebView to solve Cloudflare/anti-bot challenges. We don't
 * bundle a WebView-based solver, so this is a PASS-THROUGH interceptor: it lets
 * plugins that attach a CloudflareKiller load + run (no `NoClassDefFoundError`),
 * and their requests work on sites that AREN'T actively challenging. Sites that
 * genuinely gate behind Cloudflare still won't load (they'd need the real
 * WebView solver — out of scope).
 */
class CloudflareKiller : Interceptor {
    val savedCookies: MutableMap<String, Map<String, String>> = mutableMapOf()

    override fun intercept(chain: Interceptor.Chain): Response =
        chain.proceed(chain.request())
}
