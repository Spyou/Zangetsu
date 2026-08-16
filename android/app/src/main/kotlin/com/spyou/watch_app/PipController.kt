package com.spyou.watch_app

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.MethodChannel

/**
 * Picture-in-Picture: the window's action buttons, its aspect ratio, and the
 * animation it enters with.
 *
 * Split out of MainActivity because all of it is PiP-only — nothing here
 * touches playback. The buttons don't act on the player directly either; a tap
 * arrives as a broadcast, gets forwarded to Dart over the existing pip channel,
 * and Dart calls the same seekBy/togglePlay the on-screen transport already
 * uses.
 */
class PipController(private val activity: Activity) {

    companion object {
        // Namespaced so no other app's broadcast can land here.
        private const val ACTION = "com.spyou.watch_app.PIP_ACTION"
        private const val EXTRA = "control"

        const val REWIND = "rewind"
        const val PLAY_PAUSE = "play_pause"
        const val FORWARD = "forward"

        /**
         * Android rejects a PiP aspect outside roughly 1:2.39 .. 2.39:1 by
         * throwing, which would crash the moment PiP is entered. Anything
         * beyond the range is clamped rather than passed through.
         */
        private const val MIN_RATIO = 0.4184f
        private const val MAX_RATIO = 2.39f
    }

    /** Channel to Dart; set by MainActivity once the engine exists. */
    var channel: MethodChannel? = null

    private var playing = true
    private var aspect = Rational(16, 9)
    private var receiverRegistered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION) return
            val control = intent.getStringExtra(EXTRA) ?: return
            // Optimistic local flip so the icon swaps immediately rather than
            // waiting for Dart to come back — at PiP size a late icon reads as
            // an unresponsive button. Dart's own state push corrects it if the
            // toggle didn't take.
            if (control == PLAY_PAUSE) {
                playing = !playing
                applyParams()
            }
            channel?.invokeMethod(control, null)
        }
    }

    fun register() {
        if (receiverRegistered || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val filter = IntentFilter(ACTION)
        // API 33 made the exported flag mandatory. This receiver only ever
        // hears our own PendingIntents, so it stays unexported.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    fun unregister() {
        if (!receiverRegistered) return
        runCatching { activity.unregisterReceiver(receiver) }
        receiverRegistered = false
    }

    /**
     * Called from Dart whenever playback state or video size changes.
     *
     * The play/pause icon is baked into the RemoteAction, so it can only change
     * by rebuilding the actions and handing Android a fresh set — there's no
     * "update one button" API. Cheap enough to just re-apply.
     */
    fun setState(isPlaying: Boolean, videoWidth: Int, videoHeight: Int) {
        playing = isPlaying
        if (videoWidth > 0 && videoHeight > 0) {
            val r = videoWidth.toFloat() / videoHeight.toFloat()
            aspect = when {
                r < MIN_RATIO -> Rational(419, 1000)
                r > MAX_RATIO -> Rational(239, 100)
                else -> Rational(videoWidth, videoHeight)
            }
        }
        applyParams()
    }

    /** Enter PiP now (the player's PiP button). */
    fun enter(sourceRect: Rect?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (activity.isInPictureInPictureMode) return true
        return runCatching {
            activity.enterPictureInPictureMode(buildParams(sourceRect).build())
        }.getOrDefault(false)
    }

    /** Re-push the current params — actions, aspect, everything. */
    fun applyParams(sourceRect: Rect? = null) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            activity.setPictureInPictureParams(buildParams(sourceRect).build())
        }
    }

    /** Whether auto-enter-on-leave is armed (Android 12+ only). */
    var autoEnter = false
        set(value) {
            field = value
            applyParams()
        }

    private fun buildParams(sourceRect: Rect?): PictureInPictureParams.Builder {
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(aspect)
            .setActions(buildActions())
        // The rectangle the window animates out of. Without it Android
        // cross-fades; with it the video appears to shrink into the corner,
        // which is the difference people read as "proper" PiP.
        if (sourceRect != null && !sourceRect.isEmpty) {
            b.setSourceRectHint(sourceRect)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(autoEnter)
            // Video content: resize without the crossfade Android otherwise
            // applies, which looks like a stutter on a small window.
            b.setSeamlessResizeEnabled(true)
        }
        return b
    }

    private fun buildActions(): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()
        // Most devices allow three; some allow fewer. Asking for more than the
        // device permits throws, so the list is trimmed to whatever it reports
        // and play/pause is ordered to survive the trim.
        val max = runCatching { activity.maxNumPictureInPictureActions }
            .getOrDefault(3)
        if (max <= 0) return emptyList()

        val all = listOf(
            action(REWIND, "Rewind 10 seconds", R.drawable.ic_pip_rewind, 1),
            // Order matters below when the device allows fewer than three.
            action(
                PLAY_PAUSE,
                if (playing) "Pause" else "Play",
                if (playing) R.drawable.ic_pip_pause else R.drawable.ic_pip_play,
                2,
            ),
            action(FORWARD, "Forward 10 seconds", R.drawable.ic_pip_forward, 3),
        )
        // Fewer slots than three: keep play/pause first, it's the one that
        // matters. Otherwise a two-action device would show rewind + play and
        // drop forward, which reads as broken.
        return if (all.size <= max) all else listOf(all[1]) + all.filterIndexed { i, _ -> i != 1 }
            .take(max - 1)
    }

    private fun action(
        control: String,
        title: String,
        iconRes: Int,
        requestCode: Int,
    ): RemoteAction {
        val intent = Intent(ACTION)
            .putExtra(EXTRA, control)
            // Explicit package: an implicit broadcast can't be delivered on
            // newer Android, and this keeps it to our own process regardless.
            .setPackage(activity.packageName)
        // API 31 made mutability explicit; these carry nothing that needs
        // filling in later, so they're immutable.
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pending = PendingIntent.getBroadcast(activity, requestCode, intent, flags)
        return RemoteAction(
            Icon.createWithResource(activity, iconRes),
            title,
            title,
            pending,
        )
    }
}
