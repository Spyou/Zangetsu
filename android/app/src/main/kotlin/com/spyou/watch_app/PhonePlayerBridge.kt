package com.spyou.watch_app

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.PlayerView
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

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
    private var flutterHost: Pair<Activity, FlutterEngine>? = null

    internal fun dockHost(): MainActivity? = flutterHost?.first as? MainActivity

    internal fun watchDataFor(session: Long): Map<String, Any?> =
        watchData?.takeIf { it.first == session }?.second.orEmpty()

    internal fun clearWatchData(session: Long) {
        if (watchData?.first == session) watchData = null
    }

    fun register(engine: FlutterEngine, activity: Activity) {
        flutterHost = activity to engine
        engine.platformViewsController.registry.registerViewFactory(
            "zangetsu/phone_player_dock",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val session = (args as? Number)?.toLong()
                    val view = LayoutInflater.from(context)
                        .inflate(R.layout.phone_player_dock, null) as PlayerView
                    val owner = PhonePlayerActivity.active?.takeIf { it.sessionId == session }
                    owner?.attachDockView(view)
                    return object : PlatformView {
                        override fun getView(): View = view
                        override fun dispose() { owner?.detachDockView(view) }
                    }
                }
            },
        )
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "launch" -> launch(activity, call, result)
                "dockShown" -> {
                    // The app's mini player is on screen: the native card can leave.
                    val session = call.argument<Number>("sessionId")?.toLong()
                    PhonePlayerActivity.active?.takeIf { it.sessionId == session }?.completeDockHandoff()
                    result.success(true)
                }
                "toggleDockPlayback", "closeDock", "restoreDock" -> {
                    val session = call.argument<Number>("sessionId")?.toLong()
                    val owner = PhonePlayerActivity.active?.takeIf { it.sessionId == session }
                    result.success(owner?.dockCommand(call.method) == true)
                }
                "cacheInfo", "clearPlaybackCache" -> Thread({
                    try {
                        val prepared = runCatching {
                            PhonePlaybackCache.prepare(activity,
                                (call.argument<Number>("diskCacheGb")?.toLong() ?: 2L).coerceIn(1L, 20L) * 1024 * 1024 * 1024)
                        }
                        val response: Any = if (call.method == "clearPlaybackCache") {
                            prepared.getOrThrow()
                            PhonePlaybackCache.clear()
                        } else mapOf("nativeLimitMb" to PhonePlaybackCache.nativeLimitMb(activity),
                            "javaLimitMb" to Runtime.getRuntime().maxMemory() / (4L * 1024 * 1024),
                            "diskBytes" to PhonePlaybackCache.sizeBytes(), "cacheError" to prepared.isFailure)
                        activity.runOnUiThread { result.success(response) }
                    } catch (_: Exception) {
                        activity.runOnUiThread { result.error("cache_unavailable", "Playback cache is unavailable", null) }
                    }
                }, "ZangetsuCacheInfo").start()
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
                "addLocalSubtitle" -> {
                    val target = PhonePlayerActivity.active
                    val session = call.argument<Number>("sessionId")?.toLong()
                    val path = call.argument<String>("path")
                    if (target != null && target.sessionId == session && !path.isNullOrBlank()) {
                        target.addLocalSubtitle(
                            path,
                            call.argument<String>("label").orEmpty().ifBlank { "Subtitle" },
                            call.argument<String>("language"),
                        )
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "setSubtitlePreference" -> {
                    val target = PhonePlayerActivity.active
                    val session = call.argument<Number>("sessionId")?.toLong()
                    val value = call.argument<String>("value")
                    if (target != null && target.sessionId == session && value != null) {
                        target.updateSubtitlePreference(value)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "updateSubtitleStyle" -> {
                    val target = PhonePlayerActivity.active
                    val session = call.argument<Number>("sessionId")?.toLong()
                    val scale = call.argument<Number>("scale")?.toFloat()
                    val position = call.argument<Number>("position")?.toInt()
                    val foreground = call.argument<Number>("foreground")?.toInt()
                    val background = call.argument<Number>("background")?.toInt()
                    val outlineType = call.argument<String>("outlineType")
                    val outlineWidth = call.argument<Number>("outlineWidth")?.toFloat()
                    val edgeColor = call.argument<Number>("edgeColor")?.toInt()
                    if (target != null && target.sessionId == session && scale?.isFinite() == true &&
                        position != null && foreground != null && background != null &&
                        outlineType != null && outlineWidth != null && edgeColor != null
                    ) {
                        target.updateSubtitleStyle(scale, position, foreground, background,
                            outlineType, outlineWidth, edgeColor, call.argument<String>("fontPath"))
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
        PhonePlayerActivity.active?.takeIf { it.docked }?.finish()
        flutterHost = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** Shows one of Dart's Flutter sheets over the player; [method] says which. */
    internal fun openFlutterSheet(player: PhonePlayerActivity, method: String): Dialog? {
        if (player.isFinishing || player.isDestroyed) return null
        val (host, engine) = flutterHost ?: return null
        val bridge = channel ?: return null
        val original = host.findViewById<ViewGroup>(R.id.flutter_container)
            ?.getChildAt(0) as? FlutterView ?: return null
        if (original.attachedFlutterEngine !== engine || host.isDestroyed) return null
        val texture = FlutterTextureView(player).apply { isOpaque = false }
        val overlay = FlutterView(player, texture)
        val args = mapOf("sessionId" to player.sessionId)
        var closedByFlutter = false
        val dialog = object : Dialog(player, android.R.style.Theme_DeviceDefault_NoActionBar) {
            @Deprecated("Flutter handles back navigation in the overlay")
            override fun onBackPressed() {
                engine.navigationChannel.popRoute()
            }
        }
        dialog.setContentView(overlay)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setFormat(PixelFormat.TRANSLUCENT)
            clearFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            WindowCompat.setDecorFitsSystemWindows(this, false)
            decorView.systemUiVisibility = player.window.decorView.systemUiVisibility
        }
        fun restoreHost() {
            overlay.detachFromFlutterEngine()
            if (!host.isDestroyed) {
                original.attachToFlutterEngine(engine)
                if ((host as? LifecycleOwner)?.lifecycle?.currentState == Lifecycle.State.RESUMED) {
                    engine.lifecycleChannel.appIsResumed()
                } else {
                    engine.lifecycleChannel.appIsPaused()
                }
            }
        }
        dialog.setOnDismissListener {
            restoreHost()
            if (!closedByFlutter) bridge.invokeMethod("closeSubtitleStyle", args)
        }
        original.detachFromFlutterEngine()
        overlay.attachToFlutterEngine(engine)
        try {
            dialog.show()
        } catch (_: android.view.WindowManager.BadTokenException) {
            restoreHost()
            return null
        }
        dialog.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        bridge.invokeMethod(method, args, object : MethodChannel.Result {
            override fun success(result: Any?) {
                closedByFlutter = true
                dialog.dismiss()
            }
            override fun error(code: String, message: String?, details: Any?) = success(null)
            override fun notImplemented() = success(null)
        })
        engine.lifecycleChannel.appIsResumed()
        engine.lifecycleChannel.aWindowIsFocused()
        return dialog
    }

    internal fun setSubtitleOverlayResumed(resumed: Boolean) {
        val lifecycle = flutterHost?.second?.lifecycleChannel ?: return
        if (resumed) lifecycle.appIsResumed() else lifecycle.appIsPaused()
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
            i.putExtra(PhonePlayerIntent.EXTRA_AUTO_ENGINE_FALLBACK,
                call.argument<Boolean>("autoPlayerFallback") ?: false)
            i.putExtra(PhonePlayerIntent.EXTRA_AMBIENT_ENABLED,
                call.argument<Boolean>("ambientPlayer") ?: true)
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
            i.putExtra(PhonePlayerIntent.EXTRA_DECODER_MODE, call.argument<String>("decoderMode"))
            i.putExtra(PhonePlayerIntent.EXTRA_NATIVE_CACHE, call.argument<Boolean>("nativeCacheEnabled") ?: false)
            i.putExtra(PhonePlayerIntent.EXTRA_NATIVE_CACHE_MB,
                (call.argument<Number>("nativeCacheMb")?.toInt() ?: 128).coerceIn(32, 512))
            i.putExtra(PhonePlayerIntent.EXTRA_DISK_CACHE, call.argument<Boolean>("diskCacheEnabled") ?: false)
            i.putExtra(PhonePlayerIntent.EXTRA_DISK_CACHE_GB,
                (call.argument<Number>("diskCacheGb")?.toInt() ?: 2).coerceIn(1, 20))
            i.putExtra(
                PhonePlayerIntent.EXTRA_SPEED,
                (call.argument<Number>("defaultSpeed") ?: 1.0).toFloat(),
            )
            i.putExtra(PhonePlayerIntent.EXTRA_HOLD_SPEED, call.argument<Boolean>("holdSpeed") ?: true)
            i.putExtra(
                PhonePlayerIntent.EXTRA_AUTO_RESUME,
                call.argument<Boolean>("autoResume") ?: true,
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_AUTO_PIP,
                call.argument<Boolean>("autoPip") ?: false,
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_IN_APP_MINI_PLAYER,
                call.argument<Boolean>("inAppMiniPlayer") ?: true,
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
                PhonePlayerIntent.EXTRA_SUB_OUTLINE_TYPE,
                call.argument<String>("subtitleOutlineType") ?: "soft",
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_OUTLINE_WIDTH,
                (call.argument<Number>("subtitleOutlineWidth") ?: 2.0).toFloat(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_EDGE_COLOR,
                (call.argument<Number>("subtitleEdgeColor") ?: android.graphics.Color.BLACK).toInt(),
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_PREFERENCE,
                call.argument<String>("subtitlePreference") ?: "",
            )
            i.putExtra(
                PhonePlayerIntent.EXTRA_SUB_POSITION,
                (call.argument<Number>("subtitlePosition") ?: 95).toInt(),
            )
            call.argument<String>("subtitleFontPath")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_SUB_FONT, it) }
            for (key in listOf("loadingArtwork", "loadingLogo")) {
                call.argument<String>(key)?.let { i.putExtra(key, it) }
            }
            val artworkHeaders = call.argument<Map<String, String>>("loadingArtworkHeaders")
            i.putExtra("loadingArtworkHeaders", artworkHeaders.orEmpty()
                .flatMap { (key, value) -> listOf(key, value) }.toTypedArray())
            call.argument<String>("cover")
                ?.let { i.putExtra(PhonePlayerIntent.EXTRA_COVER, it) }
            i.putExtra(
                PhonePlayerIntent.EXTRA_ORIENTATION,
                call.argument<String>("playerOrientation") ?: "landscape",
            )
            i.putExtra(PhonePlayerIntent.EXTRA_PORTRAIT_VIDEO_EDGE_TO_EDGE,
                call.argument<Boolean>("portraitVideoEdgeToEdge") ?: false)
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
