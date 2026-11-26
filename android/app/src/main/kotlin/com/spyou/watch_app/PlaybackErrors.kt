package com.spyou.watch_app

import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource

/**
 * Pure playback-error rules for the TV player, kept apart so they can be
 * unit-tested. They match what the phone player already does in-line
 * (software-decoder retry on 4001..4005, fresh links after an HTTP 403).
 */
@UnstableApi
internal object PlaybackErrors {
    /** Decoder init / query / decoding / format errors (4001..4005). */
    fun isDecoderError(code: Int): Boolean =
        code in PlaybackException.ERROR_CODE_DECODER_INIT_FAILED..
            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED

    /** True when any cause in the chain is an HTTP 403 response. */
    fun isForbidden(error: Throwable?): Boolean =
        generateSequence(error) { it.cause }
            .take(16)
            .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
            .any { it.responseCode == 403 }

    /**
     * Retry the same URL once with software decoders: only for a decoder
     * error, when not already in software mode, not mid-switch, and not
     * already retried for this URL.
     */
    fun shouldRetryInSoftware(
        code: Int,
        decoderMode: Int,
        switching: Boolean,
        retriedUrl: String?,
        url: String?,
    ): Boolean =
        isDecoderError(code) &&
            decoderMode != TvPlayerActivity.DECODER_MODE_SOFTWARE_FIRST &&
            !switching &&
            !url.isNullOrEmpty() &&
            retriedUrl != url
}
