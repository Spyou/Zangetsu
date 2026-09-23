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

    private lateinit var controls: android.widget.FrameLayout
    private lateinit var btnPlay: android.widget.ImageView
    private lateinit var seek: android.widget.SeekBar
    private lateinit var positionText: android.widget.TextView
    private lateinit var durationText: android.widget.TextView
    private lateinit var titleText: android.widget.TextView
    private lateinit var episodeText: android.widget.TextView

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val hideRunnable = Runnable { hideControls() }
    private var scrubbing = false

    private val ticker = object : Runnable {
        override fun run() {
            syncProgress()
            handler.postDelayed(this, 500L)
        }
    }

    private var currentIndex = 0
    private var playbackError = false
    private var reported = false

    private var episodeCount = 1
    private var episodeLabels: Array<String> = emptyArray()
    private var switching = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        goImmersive()

        val url = intent.getStringExtra(PhonePlayerIntent.EXTRA_URL)
        if (url.isNullOrEmpty()) { finish(); return }

        setContentView(R.layout.phone_player)
        playerView = findViewById(R.id.player_view)
        loading = findViewById(R.id.loading)
        controls = findViewById(R.id.controls)
        btnPlay = findViewById(R.id.btn_play)
        seek = findViewById(R.id.seek)
        positionText = findViewById(R.id.position)
        durationText = findViewById(R.id.duration)
        titleText = findViewById(R.id.title)
        episodeText = findViewById(R.id.episode_label)

        titleText.text = intent.getStringExtra(PhonePlayerIntent.EXTRA_TITLE) ?: ""
        episodeText.text = intent.getStringExtra(PhonePlayerIntent.EXTRA_EP_LABEL) ?: ""

        currentIndex = intent.getIntExtra(PhonePlayerIntent.EXTRA_START_INDEX, 0)
        episodeCount = intent.getIntExtra(PhonePlayerIntent.EXTRA_EP_COUNT, 1)
        episodeLabels = intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_EP_LABELS) ?: emptyArray()

        findViewById<View>(R.id.btn_back).setOnClickListener { finish() }
        btnPlay.setOnClickListener { togglePlay() }
        findViewById<View>(R.id.btn_rewind).setOnClickListener { seekBy(-10_000L) }
        findViewById<View>(R.id.btn_forward).setOnClickListener { seekBy(10_000L) }
        findViewById<View>(R.id.btn_episodes).setOnClickListener { showEpisodeMenu() }
        findViewById<View>(R.id.btn_next).apply {
            visibility = if (currentIndex + 1 < episodeCount) View.VISIBLE else View.GONE
            setOnClickListener { loadEpisode(currentIndex + 1) }
        }

        seek.setOnSeekBarChangeListener(object : android.widget.SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: android.widget.SeekBar, value: Int, fromUser: Boolean) {
                if (!fromUser) return
                val d = player?.duration ?: 0L
                if (d > 0) positionText.text = fmt(d * value / 1000)
            }

            override fun onStartTrackingTouch(sb: android.widget.SeekBar) {
                scrubbing = true
                // Cancel the auto-hide: a slow scrub must not lose the bar.
                handler.removeCallbacks(hideRunnable)
            }

            override fun onStopTrackingTouch(sb: android.widget.SeekBar) {
                scrubbing = false
                val d = player?.duration ?: 0L
                if (d > 0) player?.seekTo(d * sb.progress / 1000)
                bumpControls()
            }
        })

        val taps = android.view.GestureDetector(
            this,
            object : android.view.GestureDetector.SimpleOnGestureListener() {
                override fun onSingleTapConfirmed(e: android.view.MotionEvent): Boolean {
                    if (controls.visibility == View.VISIBLE) hideControls() else showControls()
                    return true
                }

                override fun onDoubleTap(e: android.view.MotionEvent): Boolean {
                    // Left third back, right third forward; the middle is the
                    // play button's territory and is left alone.
                    val third = playerView.width / 3f
                    when {
                        e.x < third -> seekBy(-10_000L)
                        e.x > third * 2 -> seekBy(10_000L)
                        else -> togglePlay()
                    }
                    return true
                }
            },
        )
        findViewById<View>(R.id.player_root).setOnTouchListener { v, ev ->
            taps.onTouchEvent(ev)
            // Only a real release is a "click"; firing on every ACTION_MOVE
            // spams TalkBack with a click event per drag sample.
            if (ev.action == android.view.MotionEvent.ACTION_UP) v.performClick()
            true
        }

        showControls()
        // onResume (always called right after onCreate) starts the ticker;
        // starting it here too would double-post it.

        playerView.useController = false
        active = this

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

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                syncPlayIcon()
                bumpControls()
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

    private fun showEpisodeMenu() {
        if (episodeLabels.isEmpty()) return
        handler.removeCallbacks(hideRunnable) // a dialog must not race the auto-hide
        android.app.AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Episodes")
            .setSingleChoiceItems(episodeLabels, currentIndex) { dialog, which ->
                dialog.dismiss()
                if (which != currentIndex) loadEpisode(which)
            }
            .setOnDismissListener { bumpControls() }
            .show()
    }

    /** Ask Dart for [index]'s stream, then play it. */
    private fun loadEpisode(index: Int) {
        if (index < 0 || index >= episodeCount || switching) return
        val ch = PhonePlayerBridge.channel ?: return
        val p = player
        // Persist the outgoing episode before leaving it.
        if (p != null && p.duration > 0) {
            ch.invokeMethod(
                "saveProgress",
                mapOf(
                    "index" to currentIndex,
                    "positionMs" to p.currentPosition,
                    "durationMs" to p.duration,
                ),
            )
        }
        p?.pause() // don't leave the old episode running under the spinner
        switching = true
        loading.visibility = View.VISIBLE
        ch.invokeMethod(
            "resolveEpisode",
            mapOf("index" to index),
            object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    val m = result as? Map<String, Any?>
                    if (m == null) failSwitch() else applyResolved(index, m)
                }
                override fun error(code: String, msg: String?, details: Any?) = failSwitch()
                override fun notImplemented() = failSwitch()
            },
        )
    }

    private fun failSwitch() {
        switching = false
        loading.visibility = View.GONE
        android.widget.Toast
            .makeText(this, "Couldn't load that episode", android.widget.Toast.LENGTH_SHORT)
            .show()
    }

    @Suppress("UNCHECKED_CAST")
    private fun applyResolved(index: Int, m: Map<String, Any?>) {
        val url = m["url"] as? String
        if (url.isNullOrEmpty()) { failSwitch(); return }
        currentIndex = index
        episodeText.text = m["episodeLabel"] as? String ?: episodeLabels.getOrNull(index) ?: ""
        findViewById<View>(R.id.btn_next).visibility =
            if (currentIndex + 1 < episodeCount) View.VISIBLE else View.GONE
        loadStream(
            url = url,
            headers = (m["headers"] as? Map<String, String>) ?: emptyMap(),
            subs = subtitlesFrom(
                (m["subUrls"] as? List<String>) ?: emptyList(),
                (m["subLangs"] as? List<String>) ?: emptyList(),
                (m["subLabels"] as? List<String>) ?: emptyList(),
            ),
            mime = m["mimeType"] as? String,
            positionMs = (m["positionMs"] as? Number)?.toLong() ?: 0L,
        )
        switching = false // the new media's buffering drives the spinner now
        bumpControls()
    }

    private fun togglePlay() {
        val p = player ?: return
        if (p.isPlaying) p.pause() else p.play()
        syncPlayIcon()
        bumpControls()
    }

    private fun seekBy(deltaMs: Long) {
        val p = player ?: return
        p.seekTo((p.currentPosition + deltaMs).coerceAtLeast(0L))
        bumpControls()
    }

    private fun syncPlayIcon() {
        btnPlay.setImageResource(
            if (player?.isPlaying == true) R.drawable.ic_pip_pause else R.drawable.ic_pip_play,
        )
    }

    private fun syncProgress() {
        val p = player ?: return
        val d = p.duration
        if (d > 0) {
            durationText.text = fmt(d)
            if (!scrubbing) {
                seek.progress = (p.currentPosition * 1000 / d).toInt().coerceIn(0, 1000)
                positionText.text = fmt(p.currentPosition)
            }
        }
    }

    private fun showControls() {
        controls.visibility = View.VISIBLE
        syncPlayIcon()
        syncProgress()
        bumpControls()
    }

    private fun hideControls() {
        controls.visibility = View.GONE
        handler.removeCallbacks(hideRunnable)
    }

    /** Restart the auto-hide countdown; paused playback keeps the bar up. */
    private fun bumpControls() {
        handler.removeCallbacks(hideRunnable)
        if (player?.isPlaying == true) handler.postDelayed(hideRunnable, 4_000L)
    }

    private fun fmt(ms: Long): String {
        if (ms <= 0) return "0:00"
        val total = ms / 1000
        val s = total % 60
        val m = (total / 60) % 60
        val h = total / 3600
        return if (h > 0) String.format("%d:%02d:%02d", h, m, s)
        else String.format("%d:%02d", m, s)
    }

    private fun subtitlesFromIntent(): List<MediaItem.SubtitleConfiguration> = subtitlesFrom(
        (intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_SUB_URLS) ?: emptyArray()).toList(),
        (intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_SUB_LANGS) ?: emptyArray()).toList(),
        (intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_SUB_LABELS) ?: emptyArray()).toList(),
    )

    private fun subtitlesFrom(
        urls: List<String>,
        langs: List<String>,
        labels: List<String>,
    ): List<MediaItem.SubtitleConfiguration> = urls.mapIndexedNotNull { i, rawUrl ->
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
        handler.removeCallbacks(ticker)
    }

    // The ticker is stopped in onPause so it doesn't keep polling a paused
    // player and writing to invisible views while backgrounded; restart it
    // here rather than in onCreate.
    override fun onResume() {
        super.onResume()
        handler.post(ticker)
    }

    override fun onDestroy() {
        reportClosed()
        handler.removeCallbacksAndMessages(null)
        active = null
        player?.release()
        player = null
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (controls.visibility == View.VISIBLE) { hideControls(); return }
        @Suppress("DEPRECATION")
        super.onBackPressed()
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
