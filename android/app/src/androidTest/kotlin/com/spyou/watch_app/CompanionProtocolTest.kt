package com.spyou.watch_app

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.StringReader

@RunWith(AndroidJUnit4::class)
/** Regression checks for authentication nonce binding and newline frame boundaries. */
class CompanionProtocolTest {
    // Shared cross-check vector: test/companion_wire_test.dart pins the same inputs and outputs,
    // so the Kotlin TV/phone and the Dart iPhone/Apple TV compute byte-identical proofs.
    private val nonce = "0123456789abcdef".repeat(4)
    private val tvKey = "04" + "11".repeat(64)
    private val phoneKey = "04" + "22".repeat(64)
    private val clientId = "pairing-vector-client-01"

    /** Pins the version-2 transcript and both proofs to the vector shared with Dart. */
    @Test fun pairingProofMatchesSharedVector() {
        assertEquals(
            "zangetsu-pair-v2|phone|pin|$nonce|$tvKey|$phoneKey|$clientId",
            CompanionReceiver.pairingTranscript("phone", "pin", nonce, tvKey, phoneKey, clientId),
        )
        assertEquals(
            "628d73ebfb5474bcd555fd5af1286b05f59642ce69bda36677a9a4d120a9c5ff",
            CompanionReceiver.pairingProof("123456", "phone", "pin", nonce, tvKey, phoneKey, clientId),
        )
        assertEquals(
            "155534e70efa0388888ddd71d2eb3eb77515676b322035abcf52348fdc043317",
            CompanionReceiver.pairingProof("123456", "tv", "pin", nonce, tvKey, phoneKey, clientId),
        )
        assertEquals(
            "0d876c464033436d89b41ff45db5254cdef445f66f483baebc34e7f0b9873661",
            CompanionReceiver.pairingProof("tok", "phone", "remembered", nonce, tvKey, "", clientId),
        )
    }

    /** A swapped public key, another nonce, code, client or role all change the proof. */
    @Test fun proofBindsKeysNonceAndRole() {
        val proof = CompanionReceiver.pairingProof("123456", "phone", "pin", nonce, tvKey, phoneKey, clientId)
        val swappedPhone = "04" + "33".repeat(64)
        assertEquals(
            "db4a0a70dcb4805f078cd13fef5e7819ea066706e008dcf181c84646d98c116d",
            CompanionReceiver.pairingProof("123456", "phone", "pin", nonce, tvKey, swappedPhone, clientId),
        )
        assertFalse(CompanionReceiver.proofMatches(proof,
            CompanionReceiver.pairingProof("123456", "phone", "pin", nonce, tvKey, swappedPhone, clientId)))
        assertFalse(CompanionReceiver.proofMatches(proof,
            CompanionReceiver.pairingProof("123456", "phone", "pin", nonce, swappedPhone, phoneKey, clientId)))
        assertFalse(CompanionReceiver.proofMatches(proof,
            CompanionReceiver.pairingProof("123456", "phone", "pin", "f".repeat(64), tvKey, phoneKey, clientId)))
        assertFalse(CompanionReceiver.proofMatches(proof,
            CompanionReceiver.pairingProof("654321", "phone", "pin", nonce, tvKey, phoneKey, clientId)))
        assertFalse(CompanionReceiver.proofMatches(proof,
            CompanionReceiver.pairingProof("123456", "tv", "pin", nonce, tvKey, phoneKey, clientId)))
        // The old nonce-only proof is not accepted as a version-2 proof.
        assertFalse(CompanionReceiver.proofMatches(proof, CompanionReceiver.proof("123456", nonce)))
        assertTrue(CompanionReceiver.proofMatches(proof, proof))
        assertFalse(CompanionReceiver.proofMatches("abc", "ab"))
        assertEquals(2, CompanionReceiver.pairingVersion)
    }

    /** Ensures consuming one command leaves the next frame available. */
    @Test fun readsOneFrameWithoutConsumingNext() {
        val reader = StringReader("{\"id\":1}\n{\"id\":2}\n").buffered()
        assertEquals(1, CompanionReceiver.readFrame(reader).getInt("id"))
        assertEquals(2, CompanionReceiver.readFrame(reader).getInt("id"))
    }

    /** A frame past the size cap is refused instead of being buffered without limit. */
    @Test(expected = IllegalArgumentException::class)
    fun rejectsOversizedFrame() {
        CompanionReceiver.readFrame(StringReader("x".repeat(262144)).buffered())
    }

    /** A frame that ends without its newline is treated as a dropped connection. */
    @Test(expected = java.io.EOFException::class)
    fun rejectsTruncatedFrame() {
        CompanionReceiver.readFrame(StringReader("{\"id\":1}").buffered())
    }
}
