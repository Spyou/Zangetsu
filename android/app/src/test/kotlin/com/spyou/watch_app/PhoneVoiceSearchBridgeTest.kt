package com.spyou.watch_app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ResolveInfo
import android.content.pm.ServiceInfo
import android.os.Bundle
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.time.Duration
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSpeechRecognizer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class PhoneVoiceSearchBridgeTest {
    private class Messenger : BinaryMessenger {
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        val events = mutableListOf<MethodCall>()
        override fun send(channel: String, message: ByteBuffer?) {
            if (message != null) {
                val copy = message.duplicate()
                copy.flip()
                events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(copy))
            }
        }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            send(channel, message)
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
    }
    private class Reply { var count = 0; var value: Any? = null; var error: String? = null }
    private val messenger = Messenger()
    private lateinit var bridge: PhoneVoiceSearchBridge
    private lateinit var activity: Activity

    @Before fun setup() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(activity.application).grantPermissions(Manifest.permission.RECORD_AUDIO)
        val service = ResolveInfo().apply {
            serviceInfo = ServiceInfo().apply { packageName = "test.voice"; name = "Recognizer" }
        }
        shadowOf(activity.packageManager).addResolveInfoForIntent(Intent(RecognitionService.SERVICE_INTERFACE), service)
        Settings.Secure.putString(activity.contentResolver, "voice_recognition_service", "test.voice/Recognizer")
        bridge = PhoneVoiceSearchBridge(activity, messenger)
    }

    @After fun cleanup() { bridge.dispose() }

    private fun call(method: String, id: Int = 1): Reply {
        val reply = Reply()
        val buffer = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, mapOf("sessionId" to id)))
        buffer.flip()
        messenger.handler!!.onMessage(buffer) { encoded ->
            reply.count++
            encoded!!.flip()
            try { reply.value = StandardMethodCodec.INSTANCE.decodeEnvelope(encoded) }
            catch (e: FlutterException) { reply.error = e.code }
        }
        shadowOf(Looper.getMainLooper()).idle()
        return reply
    }

    @Test fun `cancel destroys recording and ignores a late transcript`() {
        val reply = call("listen")
        val recognizer = shadowOf(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        call("cancel")
        assertTrue(recognizer.isDestroyed)
        recognizer.triggerOnResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("Late title"))
        })
        assertEquals(1, reply.count)
        assertNull(reply.value)
    }

    @Test fun `final text is returned once and microphone is destroyed`() {
        val reply = call("listen")
        val recognizer = shadowOf(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        recognizer.triggerOnResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("  Bleach  "))
        })
        assertEquals("Bleach", reply.value)
        assertEquals(1, reply.count)
        assertTrue(recognizer.isDestroyed)
    }

    @Test fun `wrong session cannot cancel current recording`() {
        val reply = call("listen")
        val recognizer = shadowOf(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        call("cancel", 2)
        assertFalse(recognizer.isDestroyed)
        assertEquals(0, reply.count)
        call("cancel")
        assertTrue(recognizer.isDestroyed)
    }

    @Test fun `timeout ends recognition without leaving recording active`() {
        val reply = call("listen")
        val recognizer = shadowOf(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(30))
        assertEquals("voice_no_match", reply.error)
        assertTrue(recognizer.isDestroyed)
        assertEquals(1, reply.count)
    }

    @Test fun `missing permission never creates a recognizer`() {
        shadowOf(activity.application).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val reply = call("listen")
        assertEquals("voice_permission", reply.error)
        assertNull(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
    }

    @Test fun `destroy cancels pending request and unregisters channel`() {
        val reply = call("listen")
        val recognizer = shadowOf(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        bridge.dispose()
        assertTrue(recognizer.isDestroyed)
        assertEquals(1, reply.count)
        assertNull(messenger.handler)
    }

    @Test fun `partial words are streamed without completing the search`() {
        val reply = call("listen")
        val recognizer = shadowOf(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        assertTrue(recognizer.lastRecognizerIntent.getBooleanExtra(android.speech.RecognizerIntent.EXTRA_PARTIAL_RESULTS, false))
        recognizer.triggerOnPartialResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("  Naruto  "))
        })
        assertEquals(0, reply.count)
        val event = messenger.events.last().arguments as Map<*, *>
        assertEquals("partial", event["state"])
        assertEquals("Naruto", event["text"])
        assertEquals(1, event["sessionId"])
    }

    @Test fun `late partial words after cancel are ignored`() {
        call("listen")
        val recognizer = shadowOf(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        call("cancel")
        val count = messenger.events.size
        recognizer.triggerOnPartialResults(Bundle().apply {
            putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("Ignored"))
        })
        assertEquals(count, messenger.events.size)
    }
}
