package com.spyou.watch_app

import android.content.Context
import androidx.media3.common.util.UnstableApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

@UnstableApi
class ExoPlayerViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    // args = the Dart side's creationParams (buffer preset values). Optional —
    // a null/empty map leaves ExoPlayer on its own defaults.
    override fun create(context: Context, id: Int, args: Any?): PlatformView =
        ExoPlayerView(context, id, messenger, args as? Map<*, *>)
}
