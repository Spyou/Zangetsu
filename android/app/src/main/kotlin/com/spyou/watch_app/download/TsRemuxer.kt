package com.spyou.watch_app.download

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

/**
 * Stream-copy remux of a raw / concatenated MPEG-TS file into a real MP4
 * container, via the platform's [MediaExtractor] → [MediaMuxer]. No re-encode,
 * no quality loss.
 *
 * HLS downloads arrive as `.ts` segments concatenated back-to-back; saved with
 * a `.mp4` name they have no `moov` index and carry each segment's own
 * timestamps, so players stumble at segment boundaries (frame-skipping) and seek
 * inaccurately. Rewrapping the elementary streams into MP4 rebuilds the index
 * and a single continuous timeline, producing a genuine, seekable `.mp4`.
 *
 * Concatenated segments frequently restart their PTS mid-stream (a source that
 * resets timestamps per segment, an ad-break discontinuity), which makes the
 * raw timeline jump backwards. [MediaMuxer.writeSampleData] rejects a backwards
 * timestamp, so we re-base each track's PTS to stay monotonic across those
 * seams (what ffmpeg does) instead of aborting — that's what lets a source like
 * Vidstream produce a real MP4 rather than falling back to `.ts`.
 *
 * Returns true on success. On ANY failure — a codec MP4 can't hold (e.g.
 * AC3/MP2 audio), an unparseable stream — it deletes the partial output and
 * returns false, so the caller falls back to keeping the honestly-labelled
 * `.ts`.
 */
object TsRemuxer {

    private const val TAG = "TsRemuxer"

    fun remux(inputPath: String, outputPath: String): Boolean {
        var extractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null
        var started = false
        var ok = false
        var samples = 0
        var seams = 0
        try {
            Log.i(TAG, "remux ${File(inputPath).length()} B -> $outputPath")
            extractor = MediaExtractor().apply { setDataSource(inputPath) }
            val trackCount = extractor.trackCount
            if (trackCount == 0) return false

            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            // extractor track index -> muxer track index. Skip a track whose codec
            // MP4 can't hold rather than failing the whole file; but if nothing
            // could be added, bail so we keep the .ts.
            val indexMap = HashMap<Int, Int>()
            var maxInputSize = 512 * 1024
            for (i in 0 until trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxInputSize = maxOf(maxInputSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
                try {
                    indexMap[i] = muxer.addTrack(format)
                    extractor.selectTrack(i)
                } catch (e: Exception) {
                    // Unsupported-in-MP4 track — leave it unselected/unmapped.
                    Log.w(TAG, "addTrack[$i] mime=$mime unsupported: ${e.message}")
                }
            }
            if (indexMap.isEmpty()) { Log.w(TAG, "no addable tracks -> keep .ts"); return false }

            muxer.start()
            started = true

            // One-sample buffer. TS usually omits KEY_MAX_INPUT_SIZE, so start
            // generous (a 1080p keyframe easily tops 512 KB) and grow-and-retry if
            // a single sample is still bigger — the previous fix aborted the whole
            // remux on the first oversized I-frame.
            var bufCap = maxOf(maxInputSize, 4 * 1024 * 1024).coerceAtMost(32 * 1024 * 1024)
            var buffer = ByteBuffer.allocate(bufCap)
            val info = MediaCodec.BufferInfo()
            // Per extractor-track PTS bookkeeping. H.264 B-frame reordering makes
            // the presentation timestamp dip a few frames (<0.2s) between adjacent
            // samples — that's normal and MediaMuxer stores it as a composition
            // offset, so we pass it straight through. Only a REAL discontinuity (a
            // source that resets PTS mid-stream) jumps backwards by seconds; there
            // we re-base so the track continues just past what we've emitted.
            val discontinuityUs = 1_000_000L // 1s — far above any B-frame dip
            val seamGapUs = 33_000L
            val segMaxRaw = HashMap<Int, Long>() // max raw PTS since last (re)base
            val offset = HashMap<Int, Long>()    // added to raw PTS
            val maxOut = HashMap<Int, Long>()    // max output PTS emitted
            while (true) {
                val sampleTrack = extractor.sampleTrackIndex
                if (sampleTrack < 0) break
                val muxTrack = indexMap[sampleTrack]
                if (muxTrack == null) { extractor.advance(); continue }
                // Read the sample; if this one doesn't fit, grow the buffer and
                // retry rather than aborting the file.
                var size: Int
                while (true) {
                    try { size = extractor.readSampleData(buffer, 0); break }
                    catch (e: IllegalArgumentException) {
                        if (bufCap >= 32 * 1024 * 1024) throw e
                        bufCap = (bufCap * 2).coerceAtMost(32 * 1024 * 1024)
                        buffer = ByteBuffer.allocate(bufCap)
                        Log.w(TAG, "grew sample buffer to $bufCap")
                    }
                }
                if (size < 0) break
                val raw = extractor.sampleTime
                val pts: Long
                if (raw < 0) {
                    // Unknown timestamp — keep the timeline moving forward.
                    pts = (maxOut[sampleTrack] ?: 0L) + seamGapUs
                } else {
                    val segMax = segMaxRaw[sampleTrack]
                    if (segMax != null && raw < segMax - discontinuityUs) {
                        // Real backwards jump: re-base past the last emitted PTS.
                        offset[sampleTrack] = (maxOut[sampleTrack] ?: 0L) + seamGapUs - raw
                        segMaxRaw[sampleTrack] = raw
                        seams++
                    } else {
                        segMaxRaw[sampleTrack] = maxOf(segMax ?: raw, raw)
                    }
                    pts = raw + (offset[sampleTrack] ?: 0L)
                }
                maxOut[sampleTrack] = maxOf(maxOut[sampleTrack] ?: pts, pts)
                info.offset = 0
                info.size = size
                info.presentationTimeUs = pts
                info.flags =
                    if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                        MediaCodec.BUFFER_FLAG_KEY_FRAME
                    } else {
                        0
                    }
                muxer.writeSampleData(muxTrack, buffer, info)
                extractor.advance()
                samples++
            }
            ok = true
        } catch (e: Throwable) {
            Log.w(TAG, "remux threw after samples=$samples seams=$seams: ${e.javaClass.simpleName}: ${e.message}")
            ok = false
        } finally {
            if (started) { try { muxer?.stop() } catch (e: Throwable) { Log.w(TAG, "muxer.stop threw: ${e.message}"); ok = false } }
            try { muxer?.release() } catch (_: Throwable) {}
            try { extractor?.release() } catch (_: Throwable) {}
            if (!ok) { try { File(outputPath).delete() } catch (_: Throwable) {} }
        }
        Log.i(TAG, "remux ok=$ok samples=$samples seams=$seams out=${File(outputPath).length()} B")
        return ok
    }
}
