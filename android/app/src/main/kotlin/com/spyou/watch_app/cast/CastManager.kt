package com.spyou.watch_app.cast

import android.app.Activity
import android.util.Log
import com.spyou.watch_app.R
import androidx.mediarouter.app.MediaRouteChooserDialog
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastStatusCodes
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaTrack
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.CastState
import com.google.android.gms.cast.framework.CastStateListener
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import io.flutter.plugin.common.EventChannel

/**
 * Wraps the Google Cast SDK for Flutter via the `zangetsu/cast` MethodChannel
 * and a `zangetsu/cast/events` EventChannel.
 *
 * All public methods are safe to call from the Flutter/UI thread.
 * CastContext init is guarded so a missing-Play-Services device never crashes.
 */
class CastManager(private val activity: Activity) : EventChannel.StreamHandler {

    companion object {
        private const val TAG = "CastManager"
    }

    private var castContext: CastContext? = null
    private var currentSession: CastSession? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingLoadError: String? = null

    // ── Active device discovery ────────────────────────────────────────────────

    private var mediaRouter: MediaRouter? = null

    // Empty callback: the framework does the scanning; our CastStateListener and
    // SessionManagerListener handle state transitions. We only need the callback
    // object registered so the MediaRouter framework starts active discovery.
    private val discoveryCallback = object : MediaRouter.Callback() {}

    /**
     * Start active MediaRouter scanning so the Cast framework can discover
     * nearby Chromecast devices. Safe to call multiple times (remove-then-add).
     */
    fun startDiscovery() {
        val ctx = castContext ?: return
        activity.runOnUiThread {
            try {
                val selector = ctx.mergedSelector ?: return@runOnUiThread
                val mr = MediaRouter.getInstance(activity)
                mr.removeCallback(discoveryCallback) // idempotent
                mr.addCallback(selector, discoveryCallback, MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY)
                mediaRouter = mr
                Log.d(TAG, "startDiscovery: active scan armed")
            } catch (e: Exception) {
                Log.w(TAG, "startDiscovery: failed: ${e.message}")
            }
        }
    }

    /** Stop active MediaRouter scanning. Safe to call when not scanning. */
    fun stopDiscovery() {
        try {
            mediaRouter?.removeCallback(discoveryCallback)
            Log.d(TAG, "stopDiscovery: scan stopped")
        } catch (e: Exception) {
            Log.w(TAG, "stopDiscovery: failed: ${e.message}")
        } finally {
            mediaRouter = null
        }
    }

    // ── EventChannel.StreamHandler ─────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
        // Wire CastState changes (no device / not connected / connecting / connected).
        castContext?.addCastStateListener(castStateListener)
        // If a session is already active when Flutter subscribes, emit immediately.
        pushCurrentState()
        // Start active discovery so the Cast framework scans for nearby devices
        // immediately (without this the castState stays NO_DEVICES_AVAILABLE even
        // when a Chromecast is on the same Wi-Fi network).
        startDiscovery()
    }

    override fun onCancel(arguments: Any?) {
        castContext?.removeCastStateListener(castStateListener)
        stopDiscovery()
        eventSink = null
    }

    // ── Public API (called from MethodChannel handler in MainActivity) ─────────

    /**
     * Init Cast. Returns true if the Cast framework initialised on this device
     * (Play Services present), false otherwise. Never throws.
     */
    fun init(): Boolean {
        if (castContext != null) return true
        castContext = try {
            CastContext.getSharedInstance(activity)
        } catch (e: Exception) {
            Log.w(TAG, "CastContext unavailable: ${e.message}")
            null
        }
        castContext?.sessionManager?.addSessionManagerListener(
            sessionListener,
            CastSession::class.java,
        )
        // Grab any already-active session (e.g. user was casting before launch).
        currentSession = castContext?.sessionManager?.currentCastSession
        // If Flutter subscribed to the EventChannel before init() ran, castContext was null
        // in onListen so the listener was never added. Wire it now (remove-then-add avoids
        // a double-registration if onListen already added it when castContext was non-null).
        if (eventSink != null && castContext != null) {
            castContext?.removeCastStateListener(castStateListener)
            castContext?.addCastStateListener(castStateListener)
        }
        val supported = castContext != null
        Log.d(TAG, "init() → supported=$supported")
        return supported
    }

    /**
     * Load media on the currently-connected Cast receiver.
     * args keys: url, mime, headers (ignored — Cast SDK fetches directly),
     *            title, poster, subtitles (List<Map>), startMs.
     */
    @Suppress("UNCHECKED_CAST")
    fun loadMedia(args: Map<String, Any?>) {
        val session = currentSession ?: run {
            Log.w(TAG, "loadMedia: no active Cast session")
            return
        }
        val url = args["url"] as? String ?: return
        val mime = args["mime"] as? String ?: "video/mp4"
        val title = args["title"] as? String ?: ""
        val poster = args["poster"] as? String
        val startMs = (args["startMs"] as? Number)?.toLong() ?: 0L
        val subtitleList = args["subtitles"] as? List<Map<String, Any?>> ?: emptyList()

        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
            putString(MediaMetadata.KEY_TITLE, title)
            poster?.let {
                addImage(com.google.android.gms.common.images.WebImage(android.net.Uri.parse(it)))
            }
        }

        // Build subtitle tracks.
        val tracks = subtitleList.mapIndexedNotNull { index, sub ->
            val trackUrl = sub["url"] as? String ?: return@mapIndexedNotNull null
            val lang = sub["lang"] as? String ?: "en"
            val label = sub["label"] as? String ?: lang
            MediaTrack.Builder(index.toLong() + 1, MediaTrack.TYPE_TEXT)
                .setSubtype(MediaTrack.SUBTYPE_SUBTITLES)
                .setContentId(trackUrl)
                .setLanguage(lang)
                .setName(label)
                .build()
        }

        val mediaInfo = MediaInfo.Builder(url)
            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
            .setContentType(mime)
            .setMetadata(metadata)
            .setMediaTracks(tracks)
            .build()

        val request = MediaLoadRequestData.Builder()
            .setMediaInfo(mediaInfo)
            .setAutoplay(true)
            .setCurrentTime(startMs)
            .build()

        val client = session.remoteMediaClient
        if (client != null) {
            // Clear any previous error on a fresh load attempt.
            pendingLoadError = null
            client.load(request).setResultCallback { result ->
                if (!result.status.isSuccess) {
                    val code = result.status.statusCode
                    Log.w(TAG, "loadMedia: load failed statusCode=$code")
                    pendingLoadError = "load_failed"
                    pushCurrentState()
                }
            }
            // Register a callback so position/duration updates flow to the event sink.
            // Unregister first so a second loadMedia (e.g. next episode) never accumulates duplicates.
            client.unregisterCallback(mediaClientCallback)
            client.registerCallback(mediaClientCallback)
            Log.d(TAG, "loadMedia: sent load request url=$url startMs=$startMs")
        } else {
            Log.w(TAG, "loadMedia: remoteMediaClient is null")
        }
    }

    fun play() {
        val client = currentSession?.remoteMediaClient
        if (client != null) client.play()
        else Log.w(TAG, "play: no active session")
    }

    fun pause() {
        val client = currentSession?.remoteMediaClient
        if (client != null) client.pause()
        else Log.w(TAG, "pause: no active session")
    }

    fun seek(ms: Int) {
        val client = currentSession?.remoteMediaClient
        if (client != null) client.seek(ms.toLong())
        else Log.w(TAG, "seek: no active session")
    }

    /**
     * "Stop casting" — DISCONNECT the session (return the TV to its input), not
     * merely stop the current media. The old `client.stop()` only halted
     * playback while leaving the session connected, so the phone stayed in cast
     * mode and nothing appeared to happen. endCurrentSession(true) stops the
     * receiver app; onSessionEnded then emits the disconnected state, which the
     * player uses to leave cast mode and tear down the LAN proxy.
     */
    fun stop() {
        val sm = castContext?.sessionManager
        if (sm != null) {
            try {
                sm.endCurrentSession(true)
            } catch (e: Exception) {
                Log.w(TAG, "stop: endCurrentSession failed: ${e.message}")
                currentSession?.remoteMediaClient?.stop() // best-effort fallback
            }
        } else {
            currentSession?.remoteMediaClient?.stop()
        }
    }

    /**
     * Opens the MediaRoute device-chooser dialog so the user can pick a
     * Chromecast to connect to. Must be called on the UI thread.
     *
     * MainActivity extends FlutterActivity (plain android.app.Activity, not
     * FragmentActivity), and its window theme is the non-AppCompat LaunchTheme.
     * MediaRouteChooserDialog is an AppCompatDialog and therefore needs an
     * AppCompat-themed context; we supply one via ContextThemeWrapper while
     * keeping the activity as the window-token source.
     */
    fun pickDevice() {
        val ctx = castContext ?: run {
            Log.w(TAG, "pickDevice: CastContext not initialised")
            return
        }
        activity.runOnUiThread {
            try {
                val selector: MediaRouteSelector = ctx.mergedSelector
                    ?: MediaRouteSelector.EMPTY
                // Wrap the activity with an AppCompat-compatible theme so
                // MediaRouteChooserDialog (an AppCompatDialog) doesn't throw
                // "You need to use a Theme.AppCompat theme (or descendant)".
                val themed = android.view.ContextThemeWrapper(
                    activity,
                    R.style.Theme_CloudStreamSettings,
                )
                val dialog = MediaRouteChooserDialog(themed)
                dialog.routeSelector = selector
                dialog.show()
            } catch (e: Exception) {
                Log.w(TAG, "pickDevice: failed to show chooser: ${e.message}")
            }
        }
    }

    // ── Lifecycle cleanup ──────────────────────────────────────────────────────

    fun release() {
        stopDiscovery()
        castContext?.removeCastStateListener(castStateListener)
        castContext?.sessionManager?.removeSessionManagerListener(
            sessionListener,
            CastSession::class.java,
        )
        currentSession?.remoteMediaClient?.unregisterCallback(mediaClientCallback)
        eventSink = null
        castContext = null
        currentSession = null
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    private fun pushCurrentState(error: String? = pendingLoadError) {
        val sink = eventSink ?: return
        val state = when (castContext?.castState) {
            CastState.NO_DEVICES_AVAILABLE -> "unavailable"
            CastState.NOT_CONNECTED -> "available"
            CastState.CONNECTING -> "connecting"
            CastState.CONNECTED -> "connected"
            else -> "unavailable"
        }
        val client = currentSession?.remoteMediaClient
        val posMs = client?.approximateStreamPosition ?: 0L
        val durMs = client?.mediaStatus?.mediaInfo?.streamDuration ?: 0L
        val playing = client?.isPlaying ?: false
        val deviceName = currentSession?.castDevice?.friendlyName

        val event = mutableMapOf<String, Any?>(
            "state" to state,
            "device" to deviceName,
            "positionMs" to posMs.toInt(),
            "durationMs" to durMs.toInt(),
            "playing" to playing,
        )
        if (error != null) {
            event["error"] = error
        }
        activity.runOnUiThread { sink.success(event) }
    }

    private val castStateListener = CastStateListener { _ ->
        pushCurrentState()
    }

    private val mediaClientCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() {
            // A successful status update means media loaded; clear any prior load error.
            pendingLoadError = null
            pushCurrentState(error = null)
        }
        override fun onMetadataUpdated() {
            pushCurrentState()
        }
    }

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) {
            Log.d(TAG, "Cast session started: $sessionId device=${session.castDevice?.friendlyName}")
            currentSession = session
            session.remoteMediaClient?.unregisterCallback(mediaClientCallback)
            session.remoteMediaClient?.registerCallback(mediaClientCallback)
            pushCurrentState()
        }

        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            Log.d(TAG, "Cast session resumed wasSuspended=$wasSuspended")
            currentSession = session
            session.remoteMediaClient?.unregisterCallback(mediaClientCallback)
            session.remoteMediaClient?.registerCallback(mediaClientCallback)
            pushCurrentState()
        }

        override fun onSessionEnded(session: CastSession, error: Int) {
            Log.d(TAG, "Cast session ended error=$error (${CastStatusCodes.getStatusCodeString(error)})")
            session.remoteMediaClient?.unregisterCallback(mediaClientCallback)
            currentSession = null
            pushCurrentState()
        }

        override fun onSessionSuspended(session: CastSession, reason: Int) {
            Log.d(TAG, "Cast session suspended reason=$reason")
            pushCurrentState()
        }

        override fun onSessionStartFailed(session: CastSession, error: Int) {
            Log.w(TAG, "Cast session start failed error=$error")
            currentSession = null
            pushCurrentState()
        }

        override fun onSessionResumeFailed(session: CastSession, error: Int) {
            Log.w(TAG, "Cast session resume failed error=$error")
            currentSession = null
            pushCurrentState()
        }

        override fun onSessionStarting(session: CastSession) {}
        override fun onSessionResuming(session: CastSession, sessionId: String) {}
        override fun onSessionEnding(session: CastSession) {}
    }
}
