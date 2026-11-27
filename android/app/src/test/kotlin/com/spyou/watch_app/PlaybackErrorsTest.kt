package com.spyou.watch_app

import android.net.Uri
import androidx.media3.common.PlaybackException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
/**
 * JVM tests for [PlaybackErrors], the TV player's rules for classifying ExoPlayer failures
 * (decoder errors, HTTP 403) and deciding when to fall back to a software decoder.
 */
class PlaybackErrorsTest {
    /** Shorthands for the TvPlayerActivity decoder modes under test. */
    private val hwFirst = TvPlayerActivity.DECODER_MODE_HARDWARE_FIRST
    private val hwOnly = TvPlayerActivity.DECODER_MODE_HARDWARE_ONLY
    private val sw = TvPlayerActivity.DECODER_MODE_SOFTWARE_FIRST

    /** Only Media3's decoder range (4001-4005) counts as a decoder error. */
    @Test fun decoderErrorsAre4001To4005() {
        for (code in 4001..4005) assertTrue(PlaybackErrors.isDecoderError(code))
        assertFalse(PlaybackErrors.isDecoderError(4000))
        assertFalse(PlaybackErrors.isDecoderError(4006))
        assertFalse(PlaybackErrors.isDecoderError(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS))
    }

    /**
     * A decoder error retries in software once per URL, only from a hardware mode, and never
     * while a stream switch is already in progress.
     */
    @Test fun softwareRetryOncePerUrlFromHardwareModes() {
        val code = PlaybackException.ERROR_CODE_DECODER_INIT_FAILED
        assertTrue(PlaybackErrors.shouldRetryInSoftware(code, hwFirst, false, null, "a"))
        assertTrue(PlaybackErrors.shouldRetryInSoftware(code, hwOnly, false, "b", "a"))
        assertFalse(PlaybackErrors.shouldRetryInSoftware(code, hwFirst, false, "a", "a"))
        assertFalse(PlaybackErrors.shouldRetryInSoftware(code, sw, false, null, "a"))
        assertFalse(PlaybackErrors.shouldRetryInSoftware(code, hwFirst, true, null, "a"))
        assertFalse(PlaybackErrors.shouldRetryInSoftware(code, hwFirst, false, null, null))
        assertFalse(PlaybackErrors.shouldRetryInSoftware(
            PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS, hwFirst, false, null, "a"))
    }

    /** A 403 is detected even when wrapped inside other exceptions. */
    @Test fun forbiddenFoundAnywhereInTheCauseChain() {
        assertTrue(PlaybackErrors.isForbidden(wrapped(http(403))))
        assertFalse(PlaybackErrors.isForbidden(wrapped(http(404))))
        assertFalse(PlaybackErrors.isForbidden(wrapped(java.io.IOException("x"))))
        assertFalse(PlaybackErrors.isForbidden(null))
    }

    /** Wraps [cause] two levels deep, as ExoPlayer reports source errors. */
    private fun wrapped(cause: Throwable) = PlaybackException(
        "boom", RuntimeException(cause), PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
    )

    /** Builds the HTTP error Media3 throws for a [code] response. */
    private fun http(code: Int) = HttpDataSource.InvalidResponseCodeException(
        code, null, null, emptyMap(), DataSpec(Uri.parse("https://example.invalid/v.mkv")), ByteArray(0),
    )
}
