package com.spyou.watch_app

import android.app.Activity
import android.os.Handler
import android.os.Looper
import com.discord.socialsdk.DiscordSocialSdkInit
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Owns SDK callbacks on the main thread, including while native playback is active. */
class DiscordPresenceBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "zangetsu/discord_presence")
    private val handler = Handler(Looper.getMainLooper())
    private var running = false
    private val pump = object : Runnable {
        override fun run() {
            if (!running) return
            var event = nativePoll()
            while (event != null) {
                channel.invokeMethod(if (event == "authFailed") event else "status", event)
                event = nativePollEvent()
            }
            handler.postDelayed(this, 50)
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val token = requireNotNull(call.argument<String>("token"))
                        val appId = requireNotNull(call.argument<String>("applicationId")).toLong()
                        require(token.isNotBlank() && appId > 0)
                        System.loadLibrary("discord_partner_sdk")
                        System.loadLibrary("zangetsu_discord")
                        DiscordSocialSdkInit.setEngineActivity(activity)
                        nativeStart(appId, token)
                        if (!running) {
                            running = true
                            handler.post(pump)
                        }
                        result.success(null)
                    }
                    "update" -> {
                        check(running) { "Discord SDK is not started" }
                        val a = requireNotNull(call.argument<Map<String, Any?>>("activity"))
                        val assets = a["assets"] as? Map<*, *>
                        val timestamps = a["timestamps"] as? Map<*, *>
                        val labels = (a["buttons"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                        val metadata = a["metadata"] as? Map<*, *>
                        val urls = (metadata?.get("button_urls") as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                        require(labels.size == urls.size && labels.size <= 2)
                        nativeUpdate(
                            a["name"] as? String ?: "Zangetsu", (a["type"] as? Number)?.toInt() ?: 0,
                            a["details"] as? String, a["state"] as? String,
                            assets?.get("large_image") as? String, assets?.get("large_text") as? String,
                            assets?.get("small_image") as? String, assets?.get("small_text") as? String,
                            (timestamps?.get("start") as? Number)?.toLong() ?: 0,
                            (timestamps?.get("end") as? Number)?.toLong() ?: 0,
                            labels.toTypedArray(), urls.toTypedArray(), call.argument<String>("status") ?: "online",
                        )
                        result.success(null)
                    }
                    "clear" -> { if (running) nativeClear(); result.success(null) }
                    "close" -> { stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("DISCORD_SDK_ERROR", e.message, null)
            } catch (e: LinkageError) {
                result.error("DISCORD_SDK_UNAVAILABLE", "Discord native library could not load", null)
            }
        }
    }

    private fun stop() {
        if (!running) return
        running = false
        handler.removeCallbacks(pump)
        // The SDK needs its Activity for queued unbinds and rejects a null setter.
        nativeClose()
    }

    fun dispose() {
        stop()
        channel.setMethodCallHandler(null)
    }

    private external fun nativeStart(appId: Long, token: String)
    private external fun nativeUpdate(name: String, type: Int, details: String?, state: String?, large: String?, largeText: String?, small: String?, smallText: String?, start: Long, end: Long, labels: Array<String>, urls: Array<String>, status: String)
    private external fun nativeClear()
    private external fun nativeClose()
    private external fun nativePoll(): String?
    private external fun nativePollEvent(): String?
}
