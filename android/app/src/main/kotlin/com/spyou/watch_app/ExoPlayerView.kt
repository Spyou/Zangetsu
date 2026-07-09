package com.spyou.watch_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
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
        })
        handler.post(tick)
    }

    private fun emitState() {
        val s = sink ?: return
        s.success(
            mapOf(
                "positionMs" to player.currentPosition.toInt(),
                "durationMs" to (if (player.duration > 0) player.duration.toInt() else 0),
                "buffering" to (player.playbackState == Player.STATE_BUFFERING),
                "playing" to player.isPlaying,
                "ended" to (player.playbackState == Player.STATE_ENDED),
            ),
        )
    }

    override fun getView(): View = playerView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSource" -> {
                val url = call.argument<String>("url")
                @Suppress("UNCHECKED_CAST")
                val headers = (call.argument<Map<String, String>>("headers")) ?: emptyMap()
                if (url != null) {
                    val httpFactory = DefaultHttpDataSource.Factory()
                        .setAllowCrossProtocolRedirects(true)
                    if (headers.isNotEmpty()) httpFactory.setDefaultRequestProperties(headers)
                    val mediaSource = DefaultMediaSourceFactory(httpFactory)
                        .createMediaSource(MediaItem.fromUri(url))
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
