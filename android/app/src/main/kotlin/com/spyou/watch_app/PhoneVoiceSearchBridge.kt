package com.spyou.watch_app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Phone-only recognition; TV keeps its system speech dialog. */
class PhoneVoiceSearchBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "zangetsu/phone_voice_search")
    private val handler = Handler(Looper.getMainLooper())
    private class Session(val id: Int, val result: MethodChannel.Result) {
        var recognizer: SpeechRecognizer? = null
        var timeout: Runnable? = null
        var lastLevelAt = 0L
    }
    private var active: Session? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(SpeechRecognizer.isRecognitionAvailable(activity))
                "listen" -> listen(call.argument<Int>("sessionId"), result)
                "cancel" -> {
                    if (call.argument<Int>("sessionId") == active?.id) cancelActive()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun listen(id: Int?, result: MethodChannel.Result) {
        if (id == null || id <= 0) {
            result.error("voice_failed", "Invalid voice session", null)
            return
        }
        if (active != null) {
            result.error("voice_busy", "Voice search is already listening", null)
            return
        }
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            result.error("voice_permission", "Microphone permission is required", null)
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.error("voice_unavailable", "Voice search is unavailable", null)
            return
        }
        val session = Session(id, result)
        active = session
        try {
            val recognizer = SpeechRecognizer.createSpeechRecognizer(activity)
            session.recognizer = recognizer
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = emit(session, "listening")
                override fun onBeginningOfSpeech() = emit(session, "listening")
                override fun onEndOfSpeech() = emit(session, "processing")
                override fun onRmsChanged(rmsdB: Float) {
                    val now = SystemClock.elapsedRealtime()
                    if (rmsdB.isFinite() && now - session.lastLevelAt >= 80) {
                        session.lastLevelAt = now
                        emit(session, "level", (rmsdB / 10.0).coerceIn(0.0, 1.0))
                    }
                }
                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()?.trim()
                    finish(session, text, if (text.isNullOrEmpty()) "voice_no_match" else null)
                }
                override fun onError(error: Int) {
                    finish(session, error = when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "voice_no_match"
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "voice_permission"
                        else -> "voice_failed"
                    })
                }
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onPartialResults(partialResults: Bundle?) {
                    val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()?.trim()
                    if (!text.isNullOrEmpty()) emit(session, "partial", text = text)
                }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            session.timeout = Runnable { finish(session, error = "voice_no_match") }
            handler.postDelayed(session.timeout!!, 30_000L)
            recognizer.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            })
        } catch (_: Exception) {
            finish(session, error = "voice_failed")
        }
    }

    private fun emit(session: Session, state: String, level: Double = 0.0, text: String? = null) {
        if (active !== session) return
        channel.invokeMethod("state", mapOf("sessionId" to session.id, "state" to state, "level" to level, "text" to text))
    }

    private fun finish(session: Session, text: String? = null, error: String? = null) {
        if (active !== session) return
        active = null
        session.timeout?.let(handler::removeCallbacks)
        try { session.recognizer?.cancel() } catch (_: Exception) {}
        try { session.recognizer?.destroy() } catch (_: Exception) {}
        session.recognizer = null
        if (error == null) session.result.success(text)
        else session.result.error(error, "Voice recognition did not complete", null)
    }

    fun cancelActive() { active?.let { finish(it) } }

    fun dispose() {
        cancelActive()
        channel.setMethodCallHandler(null)
    }
}
