package com.spyou.watch_app

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Native torrent streaming engine (Phase 1 scaffold).
 *
 * This task only wires the platform channels and verifies libtorrent4j's
 * native libraries link + package for both ABIs. The real libtorrent4j session
 * + local HTTP streaming server is added in the next task. Nothing here runs
 * unless Dart calls `startStream`, so it is completely inert today.
 */
class TorrentEngine(messenger: BinaryMessenger) {
    private val method = MethodChannel(messenger, "com.spyou.watch_app/torrent")
    private val events = EventChannel(messenger, "com.spyou.watch_app/torrent/events")

    init {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "ping" -> result.success("ok")
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {}
            override fun onCancel(args: Any?) {}
        })
    }
}
