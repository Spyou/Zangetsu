package com.spyou.watch_app

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.StringReader

@RunWith(AndroidJUnit4::class)
class BetaProtocolTest {
    @Test fun proofBindsPairingCodeToConnectionNonce() {
        val proof = BetaLink.proof("123456", "unique-connection")
        assertEquals(64, proof.length)
        assertEquals(proof, BetaLink.proof("123456", "unique-connection"))
        assertNotEquals(proof, BetaLink.proof("123456", "another-connection"))
        assertNotEquals(proof, BetaLink.proof("654321", "unique-connection"))
    }

    @Test fun readsOneFrameWithoutConsumingNext() {
        val reader = StringReader("{\"id\":1}\n{\"id\":2}\n").buffered()
        assertEquals(1, BetaLink.readFrame(reader).getInt("id"))
        assertEquals(2, BetaLink.readFrame(reader).getInt("id"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsOversizedFrame() {
        BetaLink.readFrame(StringReader("x".repeat(262144)).buffered())
    }

    @Test(expected = java.io.EOFException::class)
    fun rejectsTruncatedFrame() {
        BetaLink.readFrame(StringReader("{\"id\":1}").buffered())
    }
}
