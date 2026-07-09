package com.spyou.watch_app

import android.content.Context
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

/**
 * A PlatformView hosting an ExoPlayer + [PlayerView]. PlayerView defaults to a
 * SurfaceView (`surface_type=surface_view`), which lands on the TV's hardware
 * overlay plane — the whole point of the spike. Controlled from Dart via a
 * per-view MethodChannel `zangetsu/exoplayer_<id>`.
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
        useController = false // Flutter draws any controls on top
    }
    private val channel = MethodChannel(messenger, "zangetsu/exoplayer_$id")

    init {
        channel.setMethodCallHandler(this)
    }

    override fun getView(): View = playerView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setUrl" -> {
                val url = call.argument<String>("url")
                if (url != null) {
                    player.setMediaItem(MediaItem.fromUri(url))
                    player.prepare()
                    player.playWhenReady = true
                }
                result.success(null)
            }
            "play" -> { player.play(); result.success(null) }
            "pause" -> { player.pause(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    override fun dispose() {
        channel.setMethodCallHandler(null)
        player.release()
    }
}
