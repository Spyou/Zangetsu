package com.spyou.watch_app

import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.PlaybackState
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BetaMediaSessionTest {
    @Test fun publishesRemotePlaybackAndClearsStoppedState() {
        val inst = InstrumentationRegistry.getInstrumentation()
        inst.runOnMainSync {
            val media = BetaMediaSession(inst.targetContext)
            try {
                val controller = MediaController(inst.targetContext, media.token())
                val state = JSONObject().put("active", true).put("playerForeground", true)
                    .put("appForeground", true).put("playing", true).put("title", "Remote session test")
                    .put("episodeLabel", "Episode 2").put("positionMs", 12000).put("durationMs", 90000)
                media.update(state)
                assertEquals("Remote session test", controller.metadata.getString(MediaMetadata.METADATA_KEY_TITLE))
                assertEquals(PlaybackState.STATE_PLAYING, controller.playbackState.state)
                assertEquals(12000L, controller.playbackState.position)
                assertEquals(MediaController.PlaybackInfo.PLAYBACK_TYPE_REMOTE, controller.playbackInfo.playbackType)
                media.update(state.put("playing", false))
                assertEquals(PlaybackState.STATE_PAUSED, controller.playbackState.state)
                media.update(JSONObject())
                assertEquals(PlaybackState.STATE_STOPPED, controller.playbackState.state)
            } finally { media.close() }
        }
    }
}
