package com.spyou.watch_app;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.MediaMetadata;
import android.media.VolumeProvider;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.SystemClock;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONObject;

/**
 * Mirrors the TV's playback state into an Android {@link MediaSession} so lock-screen, quick
 * settings and OEM media capsules show it, and routes their buttons back to the TV through
 * {@link RemoteCompanionBridge}. Uses remote (relative) volume playback; no audio focus or
 * silent audio, because the phone is controlling a TV, not playing anything. Owned by
 * {@link RemoteConnectionService}.
 */
final class RemoteMediaSession {
    /** The system media session and its relative remote volume control. */
    private final MediaSession session;
    private final VolumeProvider volume;
    /** Shared result sink for bridge calls: failures are only logged, nothing awaits them. */
    private final MethodChannel.Result result = new MethodChannel.Result() {
        public void success(Object value) { }
        public void error(String code, String message, Object details) {
            android.util.Log.w("ZangetsuRemote", "Media control failed: " + message);
        }
        public void notImplemented() { }
    };
    /** Registers remote transport callbacks; does not request local audio focus. */
    RemoteMediaSession(Context context) {
        session = new MediaSession(context, "Zangetsu TV remote");
        session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        session.setSessionActivity(PendingIntent.getActivity(context, 0,
            new Intent(context, MainActivity.class), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        volume = new VolumeProvider(VolumeProvider.VOLUME_CONTROL_RELATIVE, 100, 50) {
            @Override public void onAdjustVolume(int direction) {
                if (direction != 0) control(direction > 0 ? "volumeUp" : "volumeDown");
            }
        };
        session.setPlaybackToRemote(volume);
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { request("playing", "value", true); }
            @Override public void onPause() { request("playing", "value", false); }
            @Override public void onSkipToNext() { control("next"); }
            @Override public void onSkipToPrevious() { control("previous"); }
            @Override public void onFastForward() { control("forward"); }
            @Override public void onRewind() { control("rewind"); }
            @Override public void onSeekTo(long position) { request("seek", "positionMs", Math.max(0, position)); }
        });
    }
    /** Session token used by the service notification's MediaStyle. */
    MediaSession.Token token() { return session.getSessionToken(); }
    /** Routes a transport/volume action as a {@code control} MethodCall to the remote bridge. */
    private void control(String action) {
        RemoteCompanionBridge bridge = RemoteCompanionBridge.Companion.getShared();
        if (bridge == null) return;
        try { bridge.handle(new MethodCall("control", new JSONObject().put("action", action).toString()), result); }
        catch (Exception e) { result.error("control", e.getMessage(), null); }
    }
    /**
     * Sends {@code {"action": action, key: value}} straight to the companion, giving explicit
     * play/pause state or seek position instead of an ambiguous toggle.
     */
    private void request(String action, String key, Object value) {
        RemoteCompanionBridge bridge = RemoteCompanionBridge.Companion.getShared();
        if (bridge == null) return;
        try { bridge.sendCompanion(new JSONObject().put("action", action).put(key, value), result); }
        catch (Exception e) { result.error("control", e.getMessage(), null); }
    }
    /**
     * Publishes receiver metadata and position, and deactivates the session outside TV playback.
     * Reads the companion state JSON keys active, playerForeground, playing, buffering, title,
     * episodeLabel, durationMs, positionMs and volume (0-100).
     */
    void update(JSONObject state) {
        boolean active = state.optBoolean("active") && state.optBoolean("playerForeground");
        if (!active) {
            session.setPlaybackState(new PlaybackState.Builder().setState(PlaybackState.STATE_STOPPED, 0, 0).build());
            session.setActive(false);
            return;
        }
        boolean playing = state.optBoolean("playing");
        int status = state.optBoolean("buffering") ? PlaybackState.STATE_BUFFERING : playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED;
        session.setMetadata(new MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, state.optString("title", "Zangetsu"))
            .putString(MediaMetadata.METADATA_KEY_ARTIST, state.optString("episodeLabel", "Playing on TV"))
            .putLong(MediaMetadata.METADATA_KEY_DURATION, state.optLong("durationMs", 0)).build());
        session.setPlaybackState(new PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE |
                PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_SEEK_TO |
                PlaybackState.ACTION_REWIND | PlaybackState.ACTION_FAST_FORWARD)
            .setState(status, Math.max(0, state.optLong("positionMs")), playing && status != PlaybackState.STATE_BUFFERING ? 1 : 0, SystemClock.elapsedRealtime())
            .build());
        volume.setCurrentVolume(Math.max(0, Math.min(100, state.optInt("volume", 50))));
        session.setActive(true);
    }
    /** Releases the system session when the owning connection service ends. */
    void close() { session.setActive(false); session.release(); }
}
