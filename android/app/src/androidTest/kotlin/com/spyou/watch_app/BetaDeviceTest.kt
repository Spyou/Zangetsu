package com.spyou.watch_app

import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class BetaDeviceTest {
    @Test fun receiverFixture() {
        val inst = InstrumentationRegistry.getInstrumentation()
        val context = inst.targetContext
        inst.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        inst.runOnMainSync { BetaLink.start(context) }
        inst.startActivitySync(Intent(context, TvPlayerActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(TvPlayerActivity.EXTRA_URL, "asset:///beta-test.mp4")
            .putExtra(TvPlayerActivity.EXTRA_TITLE, "Beta device test")
            .putExtra(TvPlayerActivity.EXTRA_EP_LABELS, arrayOf("Local test clip")))
        inst.sendStatus(0, Bundle().apply { putString("stream", "BETA_RECEIVER ${BetaLink.addresses()} PIN ${BetaLink.pin}\n") })
        val end = SystemClock.elapsedRealtime() + 240000
        var passed = false
        while (SystemClock.elapsedRealtime() < end) {
            inst.runOnMainSync {
                val state = TvPlayerActivity.active?.betaState()
                passed = state != null && !state.optBoolean("playing") && state.optLong("positionMs") in 11000..13000 && state.optInt("volume") == 37
            }
            if (passed) break
            Thread.sleep(200)
        }
        Thread.sleep(1000)
        inst.runOnMainSync { BetaLink.stop(); TvPlayerActivity.active?.finish() }
        assertTrue("Expected phone to pause, seek to 12s, and set volume to 37%", passed)
    }

    @Test fun phoneControlsTv() {
        val inst = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        val host = args.getString("host") ?: error("host required")
        val port = args.getString("port")!!.toInt()
        val pin = args.getString("pin") ?: error("pin required")
        val activity = inst.startActivitySync(Intent(inst.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val bridge = BetaRemoteBridge(activity)
        fun call(method: String, values: Any? = null): Any? {
            val future = CompletableFuture<Any?>()
            inst.runOnMainSync {
                bridge.handle(MethodCall(method, values), object : MethodChannel.Result {
                    override fun success(result: Any?) { future.complete(result) }
                    override fun error(code: String, message: String?, details: Any?) { future.completeExceptionally(IllegalStateException(message)) }
                    override fun notImplemented() { future.completeExceptionally(IllegalStateException("Missing method")) }
                })
            }
            return future.get(100, TimeUnit.SECONDS)
        }
        fun command(action: String, vararg values: Pair<String, Any>): JSONObject {
            val request = JSONObject().put("action", action)
            values.forEach { request.put(it.first, it.second) }
            val response = JSONObject(call("command", request.toString()) as String)
            assertFalse(response.toString(), response.has("error"))
            Thread.sleep(40)
            return response
        }
        try {
            val found = call("discover") as List<*>
            inst.sendStatus(0, Bundle().apply { putString("stream", "DISCOVERED $found\n") })
            assertTrue("TV was not found using either discovery method", found.any { (it as Map<*, *>)["address"] == "$host:$port" })
            try {
                call("connect", mapOf("address" to "$host:$port", "pin" to if (pin == "111111") "222222" else "111111"))
                fail("Invalid pairing code was accepted")
            } catch (_: java.util.concurrent.ExecutionException) { /* expected */ }
            call("connect", mapOf("address" to "$host:$port", "pin" to pin))
            assertTrue(command("state").getBoolean("active"))
            command("playing", "value" to false)
            assertFalse(command("state").getBoolean("playing"))
            command("handoffResume", "index" to 0, "positionMs" to 18000)
            Thread.sleep(600)
            val resumed = command("state")
            assertTrue(resumed.getBoolean("playing"))
            assertTrue(resumed.getLong("positionMs") in 17000..22000)
            command("playing", "value" to false)
            command("seek", "positionMs" to 12000)
            Thread.sleep(500)
            command("volume", "value" to 37)
        } finally { inst.runOnMainSync { bridge.close() } }
    }
}
