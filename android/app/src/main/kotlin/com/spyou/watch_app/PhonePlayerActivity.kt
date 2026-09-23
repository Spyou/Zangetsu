package com.spyou.watch_app

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.ProgressBar
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.NextRenderersFactory

/**
 * The phone's own native video player.
 *
 * Exists because libmpv fails to link on Android 8 and older — media_kit never
 * initialises there, so the Flutter player comes up white. Reached only when
 * Settings → Playback → the experimental player toggle is on.
 *
 * Nothing about the TV player is shared or subclassed: that file belongs to
 * someone else, and a base class would mean two people editing one file and
 * each able to break the other's platform. The engine setup below is therefore
 * deliberately duplicated, and a decoding or buffering fix has to be made in
 * both places.
 */
@UnstableApi
class PhonePlayerActivity : Activity() {

    companion object {
        private const val TAG = "PhonePlayer"

        /** Foreground player, so the bridge can push late updates. */
        @JvmStatic
        @Volatile
        var active: PhonePlayerActivity? = null
    }

    private var player: ExoPlayer? = null
    private lateinit var playerView: PlayerView
    private lateinit var loading: ProgressBar

    private var currentIndex = 0
    private var playbackError = false
    private var reported = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        goImmersive()

        val url = intent.getStringExtra(PhonePlayerIntent.EXTRA_URL)
        if (url.isNullOrEmpty()) { finish(); return }

        setContentView(R.layout.phone_player)
        playerView = findViewById(R.id.player_view)
        loading = findViewById(R.id.loading)
        playerView.useController = false
        active = this

        currentIndex = intent.getIntExtra(PhonePlayerIntent.EXTRA_START_INDEX, 0)

        val exo = ExoPlayer.Builder(this, renderersFactory())
            .setLoadControl(
                BufferPresets.loadControl(
                    intent.getIntExtra(PhonePlayerIntent.EXTRA_BUF_MIN_MS, 0),
                    intent.getIntExtra(PhonePlayerIntent.EXTRA_BUF_MAX_MS, 0),
                    intent.getIntExtra(PhonePlayerIntent.EXTRA_BUF_BYTES, 0),
                    intent.getIntExtra(PhonePlayerIntent.EXTRA_BUF_BACK_MS, 0),
                ),
            )
            .build()
        player = exo
        playerView.player = exo
        exo.playbackParameters =
            PlaybackParameters(intent.getFloatExtra(PhonePlayerIntent.EXTRA_SPEED, 1f))

        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                loading.visibility =
                    if (state == Player.STATE_BUFFERING) View.VISIBLE else View.GONE
            }

            override fun onPlayerError(error: PlaybackException) {
                playbackError = true
                loading.visibility = View.GONE
                // Task 8 turns this into a real failover; for now the session
                // ends and Dart is told why.
                finish()
            }
        })

        loadStream(
            url = url,
            headers = PhonePlayerIntent.headersFromArray(
                intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_HEADERS),
            ),
            subs = subtitlesFromIntent(),
            mime = intent.getStringExtra(PhonePlayerIntent.EXTRA_MIME),
            positionMs = intent.getLongExtra(PhonePlayerIntent.EXTRA_POSITION, 0L),
        )
    }

    private fun loadStream(
        url: String,
        headers: Map<String, String>,
        subs: List<MediaItem.SubtitleConfiguration>,
        mime: String?,
        positionMs: Long,
    ) {
        val p = player ?: return
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
        if (headers.isNotEmpty()) httpFactory.setDefaultRequestProperties(headers)
        val builder = MediaItem.Builder().setUri(url)
        if (!mime.isNullOrEmpty()) builder.setMimeType(mime)
        if (subs.isNotEmpty()) builder.setSubtitleConfigurations(subs)
        // DefaultDataSource picks the reader off the scheme, so a downloaded
        // file:// or content:// plays through the local readers while streams
        // keep the headers and redirect handling above.
        val sourceFactory =
            DefaultMediaSourceFactory(DefaultDataSource.Factory(this, httpFactory))
        p.setMediaSource(sourceFactory.createMediaSource(builder.build()))
        if (positionMs > 0) p.seekTo(positionMs)
        p.prepare()
        p.playWhenReady = true
    }

    private fun subtitlesFromIntent(): List<MediaItem.SubtitleConfiguration> {
        val urls = intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_SUB_URLS) ?: return emptyList()
        val langs = intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_SUB_LANGS) ?: emptyArray()
        val labels = intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_SUB_LABELS) ?: emptyArray()
        return urls.mapIndexedNotNull { i, rawUrl ->
            if (rawUrl.isEmpty()) return@mapIndexedNotNull null
            val u = rawUrl.lowercase()
            MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(rawUrl))
                .setMimeType(
                    // An ASS/SSA track handed to the WebVTT parser throws
                    // (ParserException: "Expected WEBVTT. Got [Script Info]")
                    // and takes the whole text renderer down with it, so it
                    // needs its own branch rather than falling into TEXT_VTT.
                    when {
                        u.contains(".ass") || u.contains(".ssa") -> MimeTypes.TEXT_SSA
                        u.contains(".srt") -> MimeTypes.APPLICATION_SUBRIP
                        else -> MimeTypes.TEXT_VTT
                    },
                )
                .setLanguage(langs.getOrNull(i))
                .setLabel(labels.getOrNull(i))
                .setSelectionFlags(if (i == 0) C.SELECTION_FLAG_DEFAULT else 0)
                .build()
        }
    }

    private fun renderersFactory(): RenderersFactory =
        if (intent.getBooleanExtra(PhonePlayerIntent.EXTRA_SW_DECODE, false)) {
            NextRenderersFactory(this)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
                .setEnableDecoderFallback(true)
        } else {
            DefaultRenderersFactory(this)
        }

    /** Tell Dart the session ended, with where it ended. Runs exactly once. */
    private fun reportClosed() {
        if (reported) return
        reported = true
        val p = player
        PhonePlayerBridge.channel?.invokeMethod(
            "playerClosed",
            mapOf(
                PhonePlayerIntent.RESULT_POSITION to (p?.currentPosition ?: 0L),
                PhonePlayerIntent.RESULT_DURATION to (p?.duration ?: 0L).coerceAtLeast(0L),
                PhonePlayerIntent.RESULT_EP_INDEX to currentIndex,
                PhonePlayerIntent.RESULT_PLAYBACK_ERROR to playbackError,
            ),
        )
    }

    // A phone gets interrupted by calls and notifications; the TV player never
    // had to handle this. Pause on the way out and leave resuming to the user.
    override fun onPause() {
        super.onPause()
        player?.pause()
    }

    override fun onDestroy() {
        reportClosed()
        active = null
        player?.release()
        player = null
        super.onDestroy()
    }

    private fun goImmersive() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            )
    }
}
