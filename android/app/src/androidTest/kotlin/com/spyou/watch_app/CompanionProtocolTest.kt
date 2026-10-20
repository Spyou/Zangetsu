package com.spyou.watch_app

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.StringReader

@RunWith(AndroidJUnit4::class)
/** Regression checks for authentication nonce binding and newline frame boundaries. */
class CompanionProtocolTest {
    /** Ensures a proof cannot be reused with another connection nonce. */
    @Test fun proofBindsPairingCodeToConnectionNonce() {
        val proof = CompanionReceiver.proof("123456", "unique-connection")
        assertEquals(64, proof.length)
        assertEquals(proof, CompanionReceiver.proof("123456", "unique-connection"))
        assertNotEquals(proof, CompanionReceiver.proof("123456", "another-connection"))
        assertNotEquals(proof, CompanionReceiver.proof("654321", "unique-connection"))
    }

    /** Ensures consuming one command leaves the next frame available. */
    @Test fun readsOneFrameWithoutConsumingNext() {
        val reader = StringReader("{\"id\":1}\n{\"id\":2}\n").buffered()
        assertEquals(1, CompanionReceiver.readFrame(reader).getInt("id"))
        assertEquals(2, CompanionReceiver.readFrame(reader).getInt("id"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsOversizedFrame() {
        CompanionReceiver.readFrame(StringReader("x".repeat(262144)).buffered())
    }

    @Test(expected = java.io.EOFException::class)
    fun rejectsTruncatedFrame() {
        CompanionReceiver.readFrame(StringReader("{\"id\":1}").buffered())
    }
}
