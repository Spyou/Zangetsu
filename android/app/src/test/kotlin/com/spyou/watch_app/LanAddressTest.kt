package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LanAddressTest {

    @Test
    fun privateLanIp_acceptsRfc1918() {
        assertTrue(LanAddress.isPrivateLanIp("192.168.1.42"))
        assertTrue(LanAddress.isPrivateLanIp("10.0.0.5"))
        assertTrue(LanAddress.isPrivateLanIp("172.16.0.1"))
        assertTrue(LanAddress.isPrivateLanIp("172.31.255.254"))
    }

    @Test
    fun privateLanIp_rejectsPublicAndOutOfRange172() {
        assertFalse(LanAddress.isPrivateLanIp("8.8.8.8"))
        assertFalse(LanAddress.isPrivateLanIp("127.0.0.1"))
        assertFalse(LanAddress.isPrivateLanIp("172.15.0.1"))
        assertFalse(LanAddress.isPrivateLanIp("172.32.0.1"))
    }

    @Test
    fun usableInterface_acceptsWifiAndEthernet() {
        assertTrue(LanAddress.isUsableCastInterface("wlan0"))
        assertTrue(LanAddress.isUsableCastInterface("en0"))
        assertTrue(LanAddress.isUsableCastInterface("ap0"))
        assertTrue(LanAddress.isWifiInterface("wlan0"))
        assertTrue(LanAddress.isWifiInterface("en0"))
        assertTrue(LanAddress.isWifiInterface("ap0"))
    }

    @Test
    fun usableInterface_rejectsVpnVirtualCellular() {
        assertFalse(LanAddress.isUsableCastInterface("tun0"))
        assertFalse(LanAddress.isUsableCastInterface("ppp0"))
        assertFalse(LanAddress.isUsableCastInterface("rmnet_data0"))
        assertFalse(LanAddress.isUsableCastInterface("wg0"))
        assertFalse(LanAddress.isUsableCastInterface("utun3"))
    }

    @Test
    fun rewriteLoopbackHost_swapsPlaylistSegmentsToRequestHost() {
        val body = """
            #EXTM3U
            #EXTINF:6.0,
            http://127.0.0.1:46813/s/aaa.ts
            #EXTINF:6.0,
            http://127.0.0.1:46813/s/bbb.ts
        """.trimIndent()
        val out = LanAddress.rewriteLoopbackHost(body, 46813, "192.168.1.20:46813")
        assertTrue(out.contains("http://192.168.1.20:46813/s/aaa.ts"))
        assertTrue(out.contains("http://192.168.1.20:46813/s/bbb.ts"))
        assertFalse(out.contains("127.0.0.1"))
    }

    @Test
    fun rewriteLoopbackHost_leavesBodyAloneWhenHostBlank() {
        val body = "http://127.0.0.1:9/s/x"
        assertEquals(body, LanAddress.rewriteLoopbackHost(body, 9, ""))
        assertEquals(body, LanAddress.rewriteLoopbackHost(body, 9, "   "))
    }

    @Test
    fun rewriteLoopbackHost_doesNotTouchADifferentPort() {
        val body = "http://127.0.0.1:80/s/x"
        assertEquals(body, LanAddress.rewriteLoopbackHost(body, 46813, "192.168.1.20:46813"))
    }
}
