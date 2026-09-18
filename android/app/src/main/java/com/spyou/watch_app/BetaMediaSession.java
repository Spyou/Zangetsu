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

/** Real remote playback state for system media surfaces, including OEM capsules.
 * No audio focus or silent audio: the phone is controlling a TV, not playing it. */
final class BetaMediaSession {
    private final MediaSession session;
    private final VolumeProvider volume;
    private final MethodChannel.Result result = new MethodChannel.Result() {
        public void success(Object value) { }
        public void error(String code, String message, Object details) {
            android.util.Log.w("ZangetsuRemote", "Media control failed: " + message);
        }
        public void notImplemented() { }
    };
    BetaMediaSession(Context context) {
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
    MediaSession.Token token() { return session.getSessionToken(); }
    private void control(String action) {
        BetaRemoteBridge bridge = BetaRemoteBridge.Companion.getShared();
        if (bridge == null) return;
        try { bridge.handle(new MethodCall("control", new JSONObject().put("action", action).toString()), result); }
        catch (Exception e) { result.error("control", e.getMessage(), null); }
    }
    private void request(String action, String key, Object value) {
        BetaRemoteBridge bridge = BetaRemoteBridge.Companion.getShared();
        if (bridge == null) return;
        try { bridge.sendCompanion(new JSONObject().put("action", action).put(key, value), result); }
        catch (Exception e) { result.error("control", e.getMessage(), null); }
    }
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
    void close() { session.setActive(false); session.release(); }
}
