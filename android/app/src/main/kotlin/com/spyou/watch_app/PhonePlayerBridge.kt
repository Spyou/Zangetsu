package com.spyou.watch_app

import android.app.Activity
import android.content.Intent
import android.util.Log
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the `zangetsu/phone_player` channel and starts [PhonePlayerActivity].
 *
 * A separate object so MainActivity carries none of this: registering the
 * channel and releasing it are the only two lines it gains.
 */
@UnstableApi
object PhonePlayerBridge {
    private const val TAG = "PhonePlayerBridge"
    private const val CHANNEL = "zangetsu/phone_player"

    /** The live channel, used by the Activity for native→Dart calls. */
    @JvmStatic
    @Volatile
    var channel: MethodChannel? = null
        private set

    // Display rows stay in-process: long libraries must not fill an Intent parcel.
    private var watchData: Pair<Long, Map<String, Any?>>? = null

    internal fun watchDataFor(session: Long): Map<String, Any?> =
        watchData?.takeIf { it.first == session }?.second.orEmpty()

    internal fun clearWatchData(session: Long) {
        if (watchData?.first == session) watchData = null
    }

    fun register(engine: FlutterEngine, activity: Activity) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "launch" -> launch(activity, call, result)
                // Dart-side enrichment (e.g. the show synopsis) arriving after
                // launch. Session-checked: a stale Dart session's late result
                // must not paint over the live player's screen.
                "updateMetadata" -> {
                    val session = (call.argument<Number>("sessionId") ?: -1).toLong()
                    val target = PhonePlayerActivity.active
                    if (target != null && target.sessionId == session) {
                        target.onMetadataUpdate(
                            (call.argument<String>("showDescription") ?: "").ifEmpty { null },
                        )
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    fun dispose() {
        watchData = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    @Suppress("UNCHECKED_CAST")
    private fun launch(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        // url is optional: without it the Activity opens on its own loading
        // screen and asks Dart to resolve the first episode.
        val url = call.argument<String>("url").orEmpty()
        try {
            watchData = ((call.argument<Number>("sessionId") ?: 0).toLong() to
                call.argument<Map<String, Any?>>("watchData").orEmpty())
            val i = Intent(activity, PhonePlayerActivity::class.java)
            call.argument<Map<String, Any?>>("controlLayout")?.let {
                i.putExtra(PhonePlayerIntent.EXTRA_CONTROLS, org.json.JSONObject(it).toString())
            }
            if (url.isNotEmpty()) i.putExtra(PhonePlayerIntent.EXTRA_URL, url)
            i.putExtra(
                PhonePlayerIntent.EXTRA_HEADERS,
                PhonePlayerIntent.headersToArray(
                    call.argument<Map<String, String>>("headers"),
                ),
            )
            call.argument<String>("mimeType")?.let { i.putExtra(PhonePlayerIntent.EXTRA_MIME, it) }
            i.putExtra(
                PhonePlayerIntent.EXTRA_POSITION,
                (call.argument<Number>("positionMs") ?: 0).toLong(),
            )
            call.argument<String>("title")?.let { i.putExtra(PhonePlayerIntent.EXTRA_TITLE, it) }
            call.argument<String>("episodeLabel")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_EP_LABEL, it) }
            call.argument<List<String>>("episodeLabels")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_EP_LABELS, it.toTypedArray()) }
            i.putExtra(
                PhonePlayerIntent.EXTRA_EP_COUNT,
                (call.argument<Number>("episodeCount") ?: 1).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_IS_MOVIE,
                call.argument<Boolean>("isMovie") ?: false,
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_START_INDEX,
                (call.argument<Number>("startIndex") ?: 0).toInt(),
            )
            i.putExtra(PhonePlayerIntent.EXTRA_STREMIO_SUBTITLES, call.argument<Boolean>("stremioSubtitles") ?: false)
            call.argument<List<String>>("subUrls")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_SUB_URLS, it.toTypedArray()) }
            call.argument<List<String>>("subLangs")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_SUB_LANGS, it.toTypedArray()) }
            call.argument<List<String>>("subLabels")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_SUB_LABELS, it.toTypedArray()) }
            call.argument<List<String>>("subFormats")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_SUB_FORMATS, it.toTypedArray()) }
            call.argument<List<Boolean>>("subDefaults")
                ?.let { defaults -> i.putExtra(PhonePlayerIntent.EXTRA_SUB_DEFAULTS, defaults.toBooleanArray()) }
            i.putExtra(
                PhonePlayerIntent.EXTRA_ACCENT,
                (call.argument<Number>("accentColor") ?: 0xFFFF4D5E.toInt()).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SW_DECODE,
                call.argument<Boolean>("softwareDecoding") ?: false,
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SPEED,
                (call.argument<Number>("defaultSpeed") ?: 1.0).toFloat(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_AUTO_RESUME,
                call.argument<Boolean>("autoResume") ?: true,
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_KEEP_SCREEN_ON,
                call.argument<Boolean>("keepScreenOn") ?: true,
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_AUTOPLAY_NEXT,
                call.argument<Boolean>("autoplayNext") ?: true,
            )
            i.putExtra(PhonePlayerIntent.EXTRA_MEGA_SKIP, call.argument<Boolean>("megaSkip") ?: true)
            i.putExtra(PhonePlayerIntent.EXTRA_MEGA_SKIP_SECONDS,
                (call.argument<Number>("megaSkipSeconds") ?: 85).toInt().coerceIn(5, 180))
            i.putExtra(
                PhonePlayerIntent.EXTRA_SEEK_SECONDS,
                (call.argument<Number>("seekSeconds") ?: 10).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_BUF_MIN_MS,
                (call.argument<Number>("minBufferMs") ?: 0).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_BUF_MAX_MS,
                (call.argument<Number>("maxBufferMs") ?: 0).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_BUF_BYTES,
                (call.argument<Number>("targetBufferBytes") ?: 0).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_BUF_BACK_MS,
                (call.argument<Number>("backBufferMs") ?: 0).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_SCALE,
                (call.argument<Number>("subtitleScale") ?: 1.0).toFloat(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_FG,
                (call.argument<Number>("subtitleFgColor") ?: -1).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_BG_COLOR,
                (call.argument<Number>("subtitleBgColor") ?: 0).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_EDGE_TYPE,
                (call.argument<Number>("subtitleEdgeType") ?: 1).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_EDGE_COLOR,
                (call.argument<Number>("subtitleEdgeColor") ?: android.graphics.Color.BLACK).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_PREFERENCE,
                call.argument<String>("subtitlePreference") ?: "",
            )
            call.argument<String>("subtitleFontPath")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_SUB_FONT, it) }
            call.argument<String>("cover")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_COVER, it) }
            i.putExtra(
                PhonePlayerIntent.EXTRA_ORIENTATION,
                call.argument<String>("playerOrientation") ?: "landscape",
            )
            call.argument<String>("showDescription")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_SHOW_DESC, it) }
            call.argument<List<String>>("availableCategories")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_CATEGORIES, it.toTypedArray()) }
            i.putExtra(
                PhonePlayerIntent.EXTRA_CATEGORY,
                call.argument<String>("category") ?: "sub",
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SESSION,
                (call.argument<Number>("sessionId") ?: 0).toLong(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_COVER_HEADERS,
                PhonePlayerIntent.headersToArray(
                    call.argument<Map<String, String>>("coverHeaders"),
                ),
            )
            // No FLAG_ACTIVITY_NEW_TASK: we hold the real Activity, so the
            // player opens inside the app's own task rather than showing up
            // as a second card in recents.
            activity.startActivity(i)
            result.success(true)
        } catch (e: Exception) {
            clearWatchData((call.argument<Number>("sessionId") ?: 0).toLong())
            Log.w(TAG, "launch failed: ${e.message}")
            result.success(false)
        }
    }
}
