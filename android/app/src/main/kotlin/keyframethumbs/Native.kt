package keyframethumbs

/** JNI bridge into the `keyframe_thumbs` native library (vendored .so per
 * ABI under jniLibs/) — a standalone range-request + single-keyframe-decode
 * engine, independent of mpv/media_kit. See the keyframe-thumbs repo. */
object Native {
    init {
        System.loadLibrary("keyframe_thumbs")
    }

    /** [headers] is flat, alternating key, value, key, value... */
    external fun requestThumbnail(
        url: String,
        timeMs: Long,
        headers: Array<String>,
    ): ByteArray

    external fun releaseThumbnailSession()
}
