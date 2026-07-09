package com.spyou.watch_app

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

/**
 * A PlatformView hosting an ExoPlayer + [PlayerView] (SurfaceView → hardware
 * overlay). Controlled from Dart via `zangetsu/exoplayer_<id>` (setSource /
 * play / pause / seekTo) and streams playback state on
 * `zangetsu/exoplayer_events_<id>`.
 */
@UnstableApi
class ExoPlayerView(
    context: Context,
    id: Int,
    messenger: BinaryMessenger,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val player = ExoPlayer.Builder(context).build()
    private val playerView = PlayerView(context).apply {
        player = this@ExoPlayerView.player
        useController = false // Flutter draws the controls on top
    }
    private val channel = MethodChannel(messenger, "zangetsu/exoplayer_$id")
    private val events = EventChannel(messenger, "zangetsu/exoplayer_events_$id")
    private var sink: EventChannel.EventSink? = null

    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            emitState()
            handler.postDelayed(this, 500)
        }
    }

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, s: EventChannel.EventSink?) {
                sink = s
                emitState()
            }
            override fun onCancel(args: Any?) { sink = null }
        })
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) = emitState()
            override fun onIsPlayingChanged(isPlaying: Boolean) = emitState()
            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) = emitState()
        })
        handler.post(tick)
    }

    private fun emitState() {
        val s = sink ?: return
        val audio = mutableListOf<Map<String, Any?>>()
        val text = mutableListOf<Map<String, Any?>>()
        val groups = player.currentTracks.groups
        groups.forEachIndexed { gi, g ->
            for (ti in 0 until g.length) {
                val f = g.getTrackFormat(ti)
                val entry = mapOf(
                    "id" to "$gi:$ti",
                    "language" to (f.language ?: ""),
                    "label" to (f.label ?: ""),
                    "selected" to g.isTrackSelected(ti),
                )
                when (g.type) {
                    C.TRACK_TYPE_AUDIO -> audio.add(entry)
                    C.TRACK_TYPE_TEXT -> text.add(entry)
                }
            }
        }
        s.success(
            mapOf(
                "positionMs" to player.currentPosition.toInt(),
                "durationMs" to (if (player.duration > 0) player.duration.toInt() else 0),
                "buffering" to (player.playbackState == Player.STATE_BUFFERING),
                "playing" to player.isPlaying,
                "ended" to (player.playbackState == Player.STATE_ENDED),
                "audioTracks" to audio,
                "textTracks" to text,
            ),
        )
    }

    /** id = "<groupIndex>:<trackIndex>" into player.currentTracks.groups. */
    private fun applyTrackOverride(type: Int, id: String) {
        val parts = id.split(":")
        if (parts.size != 2) return
        val gi = parts[0].toIntOrNull() ?: return
        val ti = parts[1].toIntOrNull() ?: return
        val group = player.currentTracks.groups.getOrNull(gi) ?: return
        if (ti < 0 || ti >= group.length) return
        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, ti))
            .build()
    }

    private fun applyCaptionStyle(call: MethodCall) {
        val scale = (call.argument<Number>("scale") ?: 1.0).toDouble()
        val fontPath = call.argument<String>("fontPath")
        val fg = (call.argument<Number>("fgColor") ?: -1).toInt()
        val bg = (call.argument<Number>("bgColor") ?: 0).toInt()
        val edge = call.argument<Boolean>("edge") ?: false
        val pos = (call.argument<Number>("position") ?: 0.05).toDouble()
        val tf = fontPath?.let { runCatching { Typeface.createFromFile(it) }.getOrNull() }
        val style = CaptionStyleCompat(
            fg,
            bg,
            Color.TRANSPARENT,
            if (edge) CaptionStyleCompat.EDGE_TYPE_OUTLINE else CaptionStyleCompat.EDGE_TYPE_NONE,
            Color.BLACK,
            tf,
        )
        playerView.subtitleView?.apply {
            setApplyEmbeddedStyles(false)
            setApplyEmbeddedFontSizes(false)
            setStyle(style)
            setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * scale.toFloat())
            setBottomPaddingFraction(pos.toFloat())
        }
    }

    override fun getView(): View = playerView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSource" -> {
                val url = call.argument<String>("url")
                @Suppress("UNCHECKED_CAST")
                val headers = (call.argument<Map<String, String>>("headers")) ?: emptyMap()
                @Suppress("UNCHECKED_CAST")
                val subs = (call.argument<List<Map<String, String?>>>("subtitles")) ?: emptyList()
                if (url != null) {
                    val httpFactory = DefaultHttpDataSource.Factory()
                        .setAllowCrossProtocolRedirects(true)
                    if (headers.isNotEmpty()) httpFactory.setDefaultRequestProperties(headers)
                    val subConfigs = subs.mapNotNull { m ->
                        val su = m["url"] ?: return@mapNotNull null
                        MediaItem.SubtitleConfiguration.Builder(Uri.parse(su))
                            .setMimeType(m["mime"])
                            .setLanguage(m["lang"])
                            .setLabel(m["label"])
                            .build()
                    }
                    val item = MediaItem.Builder()
                        .setUri(url)
                        .setSubtitleConfigurations(subConfigs)
                        .build()
                    val mediaSource = DefaultMediaSourceFactory(httpFactory)
                        .createMediaSource(item)
                    player.setMediaSource(mediaSource)
                    player.prepare()
                    player.playWhenReady = true
                }
                result.success(null)
            }
            "setUrl" -> {
                val url = call.argument<String>("url")
                if (url != null) {
                    val mediaSource = DefaultMediaSourceFactory(
                        DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true),
                    ).createMediaSource(MediaItem.fromUri(url))
                    player.setMediaSource(mediaSource)
                    player.prepare()
                    player.playWhenReady = true
                }
                result.success(null)
            }
            "play" -> { player.play(); result.success(null) }
            "pause" -> { player.pause(); result.success(null) }
            "seekTo" -> {
                val ms = (call.argument<Number>("positionMs") ?: 0).toLong()
                player.seekTo(ms)
                result.success(null)
            }
            "setMaxVideoBitrate" -> {
                val bw = (call.argument<Number>("bandwidth") ?: 0).toInt()
                player.trackSelectionParameters = player.trackSelectionParameters
                    .buildUpon()
                    .setMaxVideoBitrate(if (bw > 0) bw else Int.MAX_VALUE)
                    .build()
                result.success(null)
            }
            "selectAudioTrack" -> {
                val id = call.argument<String>("id")
                if (id != null) applyTrackOverride(C.TRACK_TYPE_AUDIO, id)
                result.success(null)
            }
            "selectTextTrack" -> {
                val id = call.argument<String>("id")
                if (id == null) {
                    player.trackSelectionParameters = player.trackSelectionParameters
                        .buildUpon()
                        .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                        .build()
                } else {
                    applyTrackOverride(C.TRACK_TYPE_TEXT, id)
                }
                result.success(null)
            }
            "setCaptionStyle" -> {
                applyCaptionStyle(call)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun dispose() {
        handler.removeCallbacks(tick)
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        player.release()
    }
}
