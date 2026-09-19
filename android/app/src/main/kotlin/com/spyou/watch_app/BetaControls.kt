package com.spyou.watch_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** One decision per input. HID handles system keys; companion handles rich playback. */
class BetaControls(private val bridge: BetaRemoteBridge, private val context: Context) {
    var screenActive = false
    private var state = JSONObject()
    private var stateAt = 0L
    private val main = Handler(Looper.getMainLooper())
    private var repeat: Runnable? = null
    private var held = false
    private var lastVolume = 0L
    fun updateState(value: JSONObject) { state = value; BetaConnectionService.instance?.playbackSnapshot(value); stateAt = SystemClock.elapsedRealtime(); BetaConnectionService.instance?.playbackChanged(value.optBoolean("active") && value.optBoolean("playerForeground"), value.optBoolean("playing")) }
    fun clearState() { state = JSONObject(); BetaConnectionService.instance?.playbackSnapshot(state); stateAt = 0; BetaConnectionService.instance?.playbackChanged(false, false) }
    private val rich get() = bridge.isCompanionConnected() && state.optBoolean("appForeground") && state.optBoolean("playerForeground") && SystemClock.elapsedRealtime() - stateAt < 3000
    private val silent = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) { Toast.makeText(context, message ?: "TV disconnected", Toast.LENGTH_SHORT).show() }
        override fun notImplemented() {}
    }
    fun release() {
        repeat?.let(main::removeCallbacks); repeat = null
        if (held) runCatching { BetaConnectionService.instance?.release() }
        held = false
    }
    fun hardwareVolume(e: KeyEvent): Boolean {
        if (!screenActive || e.keyCode !in listOf(KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN)) return false
        if (e.action == KeyEvent.ACTION_DOWN && (e.repeatCount == 0 || SystemClock.elapsedRealtime() - lastVolume >= 110)) {
            lastVolume = SystemClock.elapsedRealtime()
            control(JSONObject().put("action", if (e.keyCode == KeyEvent.KEYCODE_VOLUME_UP) "volumeUp" else "volumeDown"), silent)
        }
        return true
    }
    fun notification(action: String) {
        val value = mapOf("VOLUME_UP" to "volumeUp", "VOLUME_DOWN" to "volumeDown", "REWIND" to "rewind", "FORWARD" to "forward", "PLAY_PAUSE" to "toggle")[action] ?: return
        control(JSONObject().put("action", value), silent)
    }
    fun control(c: JSONObject, result: MethodChannel.Result) {
        try {
            val action = c.optString("action")
            if (action == "release") { release(); result.success("{}"); return }
            val key = if (action == "key") c.optString("value") else action
            val press = c.optString("phase") == "press"
            if (press) release()
            val hid = BetaConnectionService.instance?.takeIf { it.isConnected() }
            val playback = mapOf("toggle" to "playing", "rewind" to "seekBy", "forward" to "seekBy", "previous" to "episode", "next" to "episode", "stop" to "closePlayer")
            if (key in playback) {
                val request = JSONObject().put("action", if (key == "stop") "closePlayer" else key)
                // Episode and 10-second controls are companion actions, never generic media keys.
                if (rich) bridge.sendCompanion(request, result)
                else bridge.sendCompanion(JSONObject().put("action", "state"), object : MethodChannel.Result {
                    override fun success(value: Any?) {
                        val current = JSONObject(value as String)
                        if (current.optBoolean("active") && current.optBoolean("playerForeground")) bridge.sendCompanion(request, result)
                        else result.error("playback", "Open playback in Zangetsu on the TV to use this control.", null)
                    }
                    override fun error(code: String, message: String?, details: Any?) { result.error(code, message, details) }
                    override fun notImplemented() { result.notImplemented() }
                })
                return
            }
            val keys = mapOf("up" to (1 to 82), "down" to (1 to 81), "left" to (1 to 80), "right" to (1 to 79), "ok" to (1 to 40), "back" to (2 to 0x224), "home" to (2 to 0x223), "menu" to (1 to 101), "escape" to (1 to 41), "power" to (2 to 0x30), "volumeUp" to (2 to 0xE9), "volumeDown" to (2 to 0xEA), "mute" to (2 to 0xE2), "toggle" to (2 to 0xCD), "rewind" to (2 to 0xB4), "forward" to (2 to 0xB3), "previous" to (2 to 0xB6), "next" to (2 to 0xB5), "stop" to (2 to 0xB7))
            val code = keys[key] ?: error("Unsupported remote button")
            if (hid != null) {
                // Always release the first key natively, even if Flutter misses pointer-up.
                hid.tap(code.first, code.second)
                if (press && key in listOf("up", "down", "left", "right", "volumeUp", "volumeDown")) {
                    val task = object : Runnable {
                        override fun run() {
                            if (repeat !== this || !hid.isConnected()) return
                            hid.tap(code.first, code.second); main.postDelayed(this, 130)
                        }
                    }
                    repeat = task; main.postDelayed(task, 450)
                }
                result.success("{}"); return
            }
            val request = when(key) {
                "volumeUp", "volumeDown" -> JSONObject().put("action", "systemVolume").put("direction", if(key == "volumeUp") 1 else -1)
                "mute" -> JSONObject().put("action", "systemMute")
                "up", "down", "left", "right", "ok", "back", "menu", "escape" -> JSONObject().put("action", "key").put("value", key)
                else -> error("Connect Bluetooth to use this control outside Zangetsu.")
            }
            bridge.sendCompanion(request, result)
            if (press && key in listOf("up", "down", "left", "right", "volumeUp", "volumeDown")) {
                val task = object : Runnable {
                    override fun run() {
                        if (repeat !== this) return
                        val task = this
                        bridge.sendCompanion(request, object : MethodChannel.Result {
                            override fun success(result: Any?) { if (repeat === task) main.postDelayed(task, 120) }
                            override fun error(code: String, message: String?, details: Any?) { release() }
                            override fun notImplemented() { release() }
                        })
                    }
                }
                repeat = task; main.postDelayed(task, 380)
            }
        } catch(e: Exception) { result.error("control", e.message, null) }
    }
}
