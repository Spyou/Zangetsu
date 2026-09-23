package com.spyou.watch_app

import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Picks the IPv4 a LAN device (Chromecast, Shield, DLNA renderer) can actually
 * reach on this phone, and rewrites loopback proxy URLs to match the host the
 * client used. Mirrors the Dart helpers in `lib/core/cast/cast_proxy.dart` so
 * the two proxies stay consistent.
 *
 * Pure predicates are unit-tested; [ipv4] walks live interfaces.
 */
object LanAddress {

    /** RFC-1918 private LAN address — the range a Cast receiver on the same
     *  Wi-Fi shares. */
    fun isPrivateLanIp(ip: String): Boolean {
        if (ip.startsWith("192.168.") || ip.startsWith("10.")) return true
        if (ip.startsWith("172.")) {
            val second = ip.split(".").getOrNull(1)?.toIntOrNull() ?: 0
            return second in 16..31
        }
        return false
    }

    /** Skip VPN / virtual / cellular interfaces whose address a Cast receiver
     *  on the LAN can't route to. */
    fun isUsableCastInterface(name: String): Boolean {
        val n = name.lowercase()
        val bad = listOf("tun", "tap", "ppp", "rmnet", "wg", "utun", "ipsec", "vpn", "pdp")
        return bad.none { n.startsWith(it) }
    }

    fun isWifiInterface(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("wlan") || n.startsWith("ap") || n.startsWith("en")
    }

    /**
     * Playlist rewrite always emits `http://127.0.0.1:<port>/…`. When the
     * client reached us via the phone's LAN IP (Chromecast, Web Video Cast →
     * Shield), swap that loopback host for the incoming `Host` header so
     * segments stay reachable.
     */
    fun rewriteLoopbackHost(body: String, port: Int, requestHost: String): String {
        if (requestHost.isBlank()) return body
        return body.replace("http://127.0.0.1:$port", "http://$requestHost")
    }

    /**
     * The phone's LAN IPv4 a Cast receiver can reach. Prefers Wi-Fi, skips
     * VPN/virtual/cellular. Null if nothing usable is up (caller falls back
     * to 127.0.0.1 — on-device players still work, remote ones don't).
     */
    fun ipv4(): String? {
        return try {
            val ifaces = NetworkInterface.getNetworkInterfaces()?.toList() ?: return null
            data class Hit(val name: String, val ip: String)
            val hits = mutableListOf<Hit>()
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                for (addr in iface.inetAddresses) {
                    if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                    val ip = addr.hostAddress ?: continue
                    hits.add(Hit(iface.name, ip))
                }
            }
            hits.firstOrNull {
                isUsableCastInterface(it.name) && isWifiInterface(it.name) && isPrivateLanIp(it.ip)
            }?.ip
                ?: hits.firstOrNull { isUsableCastInterface(it.name) && isPrivateLanIp(it.ip) }?.ip
                ?: hits.firstOrNull()?.ip
        } catch (_: Exception) {
            null
        }
    }
}
