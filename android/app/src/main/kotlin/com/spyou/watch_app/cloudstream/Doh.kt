package com.spyou.watch_app.cloudstream

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.dnsoverhttps.DnsOverHttps
import java.net.InetAddress

/**
 * Opt-in DNS-over-HTTPS for the CloudStream OkHttp client (CS sources only).
 *
 * Mirrors the Tachiyomi / CloudStream `DohProviders` pattern: a [DnsOverHttps]
 * resolver with HARD-CODED bootstrap IPs so the DoH endpoint itself resolves
 * even when the ISP blocks/poisons plain DNS — which is the whole point (bypass
 * ISP domain blocking). [DnsOverHttps] comes from the bundled CloudStream
 * library, so there's no new dependency.
 *
 * [OFF] (the default) returns the builder unchanged → identical to today.
 */
object Doh {
    const val OFF = 0
    const val CLOUDFLARE = 1
    const val GOOGLE = 2
    const val ADGUARD = 3
    const val QUAD9 = 4

    private fun ips(vararg s: String): List<InetAddress> =
        s.mapNotNull { runCatching { InetAddress.getByName(it) }.getOrNull() }

    /** Apply the selected DoH to [builder]; OFF (or unknown) leaves it untouched. */
    fun apply(builder: OkHttpClient.Builder, choice: Int): OkHttpClient.Builder {
        val url: String
        val bootstrap: List<InetAddress>
        when (choice) {
            CLOUDFLARE -> {
                url = "https://cloudflare-dns.com/dns-query"
                bootstrap = ips(
                    "1.1.1.1", "1.0.0.1",
                    "162.159.36.1", "162.159.46.1",
                    "2606:4700:4700::1111", "2606:4700:4700::1001",
                )
            }
            GOOGLE -> {
                url = "https://dns.google/dns-query"
                bootstrap = ips(
                    "8.8.8.8", "8.8.4.4",
                    "2001:4860:4860::8888", "2001:4860:4860::8844",
                )
            }
            ADGUARD -> {
                url = "https://dns.adguard-dns.com/dns-query"
                bootstrap = ips("94.140.14.14", "94.140.15.15")
            }
            QUAD9 -> {
                url = "https://dns.quad9.net/dns-query"
                bootstrap = ips(
                    "9.9.9.9", "149.112.112.112",
                    "2620:fe::fe", "2620:fe::9",
                )
            }
            else -> return builder // OFF — unchanged
        }
        return runCatching {
            val doh = DnsOverHttps.Builder()
                .client(builder.build()) // the client-so-far performs the DoH calls
                .url(url.toHttpUrl())
                .bootstrapDnsHosts(bootstrap)
                .build()
            builder.dns(doh)
        }.getOrDefault(builder) // any failure → leave DNS as-is (never break requests)
    }
}
