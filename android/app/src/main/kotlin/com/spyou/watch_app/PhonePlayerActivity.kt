package com.spyou.watch_app

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Matrix
import android.media.AudioManager
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.spyou.watch_app.cast.CastManager
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.NextRenderersFactory
import java.util.Locale

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
    private lateinit var loading: View

    private lateinit var loadingOverlay: View
    private lateinit var loadingBackdrop: android.widget.ImageView
    private lateinit var loadingTitle: android.widget.TextView
    private lateinit var loadingEpisode: android.widget.TextView
    private lateinit var loadingStatus: android.widget.TextView
    private lateinit var loadingSpinner: View
    private lateinit var loadingActions: View
    private var backdropRequested = false

    private val resolveTimeout = Runnable {
        if (switching) {
            mediaGeneration++
            failSwitch(getString(R.string.phone_player_error_timeout))
        }
    }

    /** A source that buffers forever must not look like a frozen app. */
    private val startTimeout = Runnable {
        if (!playbackStarted) failover()
    }

    private lateinit var controls: android.widget.FrameLayout
    private lateinit var quickActions: ViewGroup
    private lateinit var btnPlay: android.widget.ImageView
    private lateinit var seek: android.widget.SeekBar
    private lateinit var positionText: android.widget.TextView
    private lateinit var durationText: android.widget.TextView
    private lateinit var titleText: android.widget.TextView
    private lateinit var episodeText: android.widget.TextView

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val hideRunnable = Runnable { hideControls() }
    private var scrubbing = false
    private var controlsHiding = false

    // ── MPV-parity touch gestures ──────────────────────────────────────────
    // Same set as the MPV player: tap toggles chrome; double-tap sides seek
    // (accumulating, with a transient label); horizontal swipe scrubs with a
    // time bubble; vertical swipe left/right adjusts brightness/volume with a
    // Netflix-style HUD; pinch zooms the TextureView (1–4x, pans when zoomed).
    private var gestureMode = 0 // 0 idle, 1 horizontal scrub, 2 vertical slide
    private var downX = 0f
    private var downY = 0f
    private var hSeekBase = 0L
    private var hSeekTarget = 0L
    private var vStart = 0f
    private var vIsBrightness = true
    private var lastHudPct = -1
    private val pointers = LinkedHashMap<Int, Pair<Float, Float>>()
    private var pinchActive = false
    private var pinchEndAt = 0L
    private var pinchBaseSpan = 0f
    private var pinchBaseZoom = 1f
    private var zoom = 1f
    private var panX = 0f
    private var panY = 0f
    private var dblAccumL = 0L
    private var dblAccumR = 0L
    private val resetDbl =
        Runnable {
            dblAccumL = 0L
            dblAccumR = 0L
            dblLeft.visibility = View.GONE
            dblRight.visibility = View.GONE
        }
    private val hideHud =
        Runnable {
            hudPill.visibility = View.GONE
            seekBubble.visibility = View.GONE
        }
    private lateinit var hudPill: LinearLayout
    private lateinit var hudBar: ProgressBar
    private lateinit var hudLabel: TextView
    private lateinit var seekBubble: TextView
    private lateinit var dblLeft: TextView
    private lateinit var dblRight: TextView

    private val ticker = object : Runnable {
        override fun run() {
            syncProgress()
            handler.postDelayed(this, 250L)
        }
    }

    private var currentIndex = 0
    private var playbackError = false
    private var reported = false

    private var episodeCount = 1
    private var episodeLabels: Array<String> = emptyArray()
    private var switching = false
    private var mediaGeneration = 0
    private var failoverInFlight = false
    private var currentUrl = ""
    private val attemptedUrls = mutableSetOf<String>()
    private var autoplayNext = true
    private var seekMs = 10_000L
    private var keepScreenOn = true
    private var subtitlePreference = ""
    private var subtitlePreferenceApplied = false
    private var playbackStarted = false
    private var resizeIndex = 0

    private var mirrors: List<Map<String, Any?>> = emptyList()
    private var castManager: CastManager? = null
    private var castSupported = false
    private var moreDialog: android.app.Dialog? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        keepScreenOn = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_KEEP_SCREEN_ON, true)
        if (keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        goImmersive()

        val url = intent.getStringExtra(PhonePlayerIntent.EXTRA_URL).orEmpty()

        setContentView(R.layout.phone_player)
        playerView = findViewById(R.id.player_view)
        loading = findViewById(R.id.loading)
        loadingOverlay = findViewById(R.id.loading_overlay)
        loadingBackdrop = findViewById(R.id.loading_backdrop)
        loadingTitle = findViewById(R.id.loading_title)
        loadingEpisode = findViewById(R.id.loading_episode)
        loadingStatus = findViewById(R.id.loading_status)
        loadingSpinner = findViewById(R.id.loading_spinner)
        loadingActions = findViewById(R.id.loading_actions)
        findViewById<View>(R.id.btn_loading_retry).setOnClickListener {
            switching = false
            loadEpisode(currentIndex)
        }
        findViewById<View>(R.id.btn_loading_back).setOnClickListener { finish() }
        loadingTitle.text = intent.getStringExtra(PhonePlayerIntent.EXTRA_TITLE) ?: ""
        loadingEpisode.text = intent.getStringExtra(PhonePlayerIntent.EXTRA_EP_LABEL) ?: ""
        loadBackdrop()
        controls = findViewById(R.id.controls)
        quickActions = findViewById(R.id.quick_actions)
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
        autoplayNext = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_AUTOPLAY_NEXT, true)
        seekMs = (intent.getIntExtra(PhonePlayerIntent.EXTRA_SEEK_SECONDS, 10) * 1000L)
            .coerceAtLeast(1_000L)
        subtitlePreference = intent.getStringExtra(PhonePlayerIntent.EXTRA_SUB_PREFERENCE).orEmpty()

        findViewById<View>(R.id.btn_back).setOnClickListener { finish() }
        btnPlay.setOnClickListener { togglePlay() }
        findViewById<View>(R.id.btn_previous).setOnClickListener {
            bumpControls()
            if (currentIndex > 0) loadEpisode(currentIndex - 1)
        }
        findViewById<View>(R.id.btn_next).setOnClickListener {
            bumpControls()
            loadEpisode(currentIndex + 1)
        }
        findViewById<View>(R.id.btn_more).setOnClickListener {
            bumpControls()
            showMoreMenu()
        }
        bindQuickActions()
        val cast = CastManager(this)
        castManager = cast
        castSupported = runCatching { cast.init() }.getOrDefault(false)
        updateEpisodeNavigation()

        seek.setOnSeekBarChangeListener(object : android.widget.SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: android.widget.SeekBar, value: Int, fromUser: Boolean) {
                if (!fromUser) return
                val d = player?.duration ?: 0L
                if (d > 0) {
                    val pos = d * value / 1000
                    positionText.text = fmt(pos)
                    sb.contentDescription = getString(R.string.phone_player_desc_seek) + ", " + fmt(pos) + " of " + fmt(d)
                }
            }

            override fun onStartTrackingTouch(sb: android.widget.SeekBar) {
                scrubbing = true
                // Cancel the auto-hide: a slow scrub must not lose the bar.
                restoreControls()
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
                        e.x < third -> {
                            seekBy(-seekMs)
                            flashSeekLabel(-1)
                        }
                        e.x > third * 2 -> {
                            seekBy(seekMs)
                            flashSeekLabel(1)
                        }
                        else -> togglePlay()
                    }
                    return true
                }
            },
        )
        createGestureOverlays()
        findViewById<View>(R.id.player_root).setOnTouchListener { v, ev ->
            handlePlayerTouch(v, ev, taps)
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
        playerView.subtitleView?.apply {
            setStyle(
                androidx.media3.ui.CaptionStyleCompat(
                    intent.getIntExtra(PhonePlayerIntent.EXTRA_SUB_FG, android.graphics.Color.WHITE),
                    intent.getIntExtra(PhonePlayerIntent.EXTRA_SUB_BG_COLOR, android.graphics.Color.TRANSPARENT),
                    android.graphics.Color.TRANSPARENT, // window colour: never drawn
                    intent.getIntExtra(
                        PhonePlayerIntent.EXTRA_SUB_EDGE_TYPE,
                        androidx.media3.ui.CaptionStyleCompat.EDGE_TYPE_OUTLINE,
                    ),
                    intent.getIntExtra(
                        PhonePlayerIntent.EXTRA_SUB_EDGE_COLOR,
                        android.graphics.Color.BLACK,
                    ),
                    intent.getStringExtra(PhonePlayerIntent.EXTRA_SUB_FONT)
                        ?.let { runCatching { android.graphics.Typeface.createFromFile(it) }.getOrNull() },
                ),
            )
            // FRACTION_TEXT_SIZE, not absolute: the same setting has to read
            // the same on a small phone and a tablet.
            setFractionalTextSize(0.0533f * intent.getFloatExtra(PhonePlayerIntent.EXTRA_SUB_SCALE, 1f))
            setApplyEmbeddedStyles(false)
            setApplyEmbeddedFontSizes(false)
            invalidate()
        }
        exo.playbackParameters =
            PlaybackParameters(intent.getFloatExtra(PhonePlayerIntent.EXTRA_SPEED, 1f))

        exo.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() {
                playbackStarted = true
                sendDiscordPresence()
                PhonePlayerBridge.channel?.invokeMethod(
                    "playbackStarted",
                    mapOf("index" to currentIndex),
                )
                hideLoading()
            }

            override fun onPlaybackStateChanged(state: Int) {
                updateKeepScreenOn()
                setBuffering(
                    state == Player.STATE_BUFFERING &&
                        loadingOverlay.visibility != View.VISIBLE,
                )
                if (state == Player.STATE_READY) {
                    playbackError = false
                }
                if (state == Player.STATE_ENDED &&
                    autoplayNext &&
                    !switching &&
                    currentIndex + 1 < episodeCount
                ) {
                    loadEpisode(currentIndex + 1)
                }
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                sendDiscordPresence()
            }

            override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
                sendDiscordPresence()
            }

            override fun onTracksChanged(tracks: Tracks) {
                applySubtitlePreference(tracks)
            }

            override fun onPlayerError(error: PlaybackException) {
                playbackError = true
                setBuffering(false)
                failover()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                sendDiscordPresence()
                updateKeepScreenOn()
                syncPlayIcon()
                bumpControls()
            }
        })

        if (url.isEmpty()) {
            // No pre-resolved stream: the loading screen is already up and the
            // first resolve happens over the channel, like an episode switch.
            loadEpisode(currentIndex)
        } else {
            setLoadingStatus(getString(R.string.phone_player_status_starting))
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
    }

    /** Poster behind the status text, so a slow resolve never looks frozen. */
    private fun loadBackdrop() {
        if (backdropRequested) return
        val url = intent.getStringExtra(PhonePlayerIntent.EXTRA_COVER).orEmpty()
        if (url.isEmpty()) return
        backdropRequested = true
        val headers = PhonePlayerIntent.headersFromArray(
            intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_COVER_HEADERS),
        )
        Thread {
            val bitmap = runCatching {
                val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 6_000
                conn.readTimeout = 6_000
                for ((k, v) in headers) conn.setRequestProperty(k, v)
                conn.inputStream.use { android.graphics.BitmapFactory.decodeStream(it) }
            }.getOrNull()
            if (bitmap != null) {
                runOnUiThread {
                    if (!isFinishing && !isDestroyed) loadingBackdrop.setImageBitmap(bitmap)
                }
            }
        }.start()
    }

    private fun setLoadingStatus(text: String) {
        loadingStatus.text = text
    }

    private fun showLoading(episodeLabel: String?) {
        handler.removeCallbacks(resolveTimeout)
        // The control chrome duplicates the loading title and reads through the
        // scrim; it comes back on the first tap after playback starts.
        handler.removeCallbacks(hideRunnable)
        controlsHiding = false
        controls.animate().cancel()
        controls.visibility = View.GONE
        loadingOverlay.visibility = View.VISIBLE
        loadingSpinner.visibility = View.VISIBLE
        loadingActions.visibility = View.GONE
        loadingStatus.visibility = View.VISIBLE
        loadingEpisode.text = episodeLabel ?: episodeText.text
        setLoadingStatus(getString(R.string.phone_player_status_finding))
        setBuffering(false)
    }

    /** The center pause button is the same solid accent circle the indicator
     *  draws over; hide it while buffering or the morph reads as one blob. */
    private fun setBuffering(visible: Boolean) {
        loading.visibility = if (visible) View.VISIBLE else View.GONE
        btnPlay.visibility = if (visible) View.INVISIBLE else View.VISIBLE
    }

    private fun hideLoading() {
        handler.removeCallbacks(resolveTimeout)
        handler.removeCallbacks(startTimeout)
        loadingOverlay.visibility = View.GONE
        setBuffering(false)
    }

    private fun showLoadError(message: String) {
        handler.removeCallbacks(resolveTimeout)
        handler.removeCallbacks(startTimeout)
        loadingOverlay.visibility = View.VISIBLE
        loadingSpinner.visibility = View.GONE
        loadingStatus.visibility = View.VISIBLE
        setLoadingStatus(message)
        loadingActions.visibility = View.VISIBLE
        setBuffering(false)
    }

    private fun updateEpisodeNavigation() {
        val prev = findViewById<View>(R.id.btn_previous)
        val next = findViewById<View>(R.id.btn_next)
        val hasPrev = currentIndex > 0
        val hasNext = currentIndex + 1 < episodeCount
        prev.visibility = if (hasPrev) View.VISIBLE else View.INVISIBLE
        next.visibility = if (hasNext) View.VISIBLE else View.INVISIBLE
        prev.isEnabled = hasPrev
        next.isEnabled = hasNext
        prev.alpha = if (hasPrev) 1f else 0.4f
        next.alpha = if (hasNext) 1f else 0.4f
        prev.isFocusable = hasPrev
        next.isFocusable = hasNext
    }

    private fun bindQuickActions() {
        quickActions.findViewById<View>(R.id.btn_rotate).setOnClickListener { toggleRotation() }
        quickActions.findViewById<View>(R.id.quick_episodes).setOnClickListener { showEpisodeMenu() }
        quickActions.findViewById<View>(R.id.quick_sources).setOnClickListener { showSourceMenu() }
        quickActions.findViewById<View>(R.id.quick_tracks).setOnClickListener { showTracksMenu() }
        quickActions.findViewById<View>(R.id.quick_quality).setOnClickListener { showQualityMenu() }
        quickActions.findViewById<View>(R.id.quick_speed).setOnClickListener { showSpeedMenu() }
        quickActions.findViewById<View>(R.id.quick_display).setOnClickListener { showDisplayMenu() }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        moreDialog?.dismiss()
        updateOrientationLayout()
        val parent = quickActions.parent as ViewGroup
        val index = parent.indexOfChild(quickActions)
        parent.removeViewAt(index)
        quickActions = layoutInflater.inflate(R.layout.phone_player_quick_actions, parent, false) as ViewGroup
        parent.addView(quickActions, index)
        bindQuickActions()
    }

    private fun updateOrientationLayout() {
        val topScrim = controls.findViewById<View>(R.id.top_scrim)
        topScrim.layoutParams = topScrim.layoutParams.apply {
            height = resources.getDimensionPixelSize(R.dimen.phone_player_top_scrim_height)
        }
        val bottomScrim = controls.findViewById<View>(R.id.bottom_scrim)
        bottomScrim.layoutParams = bottomScrim.layoutParams.apply {
            height = resources.getDimensionPixelSize(R.dimen.phone_player_bottom_scrim_height)
        }
        val topBar = controls.findViewById<View>(R.id.top_bar)
        val topBarParams = topBar.layoutParams as android.widget.FrameLayout.LayoutParams
        topBarParams.marginStart = resources.getDimensionPixelSize(R.dimen.phone_player_top_bar_side_margin)
        topBarParams.marginEnd = resources.getDimensionPixelSize(R.dimen.phone_player_top_bar_side_margin)
        topBarParams.topMargin = resources.getDimensionPixelSize(R.dimen.phone_player_top_bar_top_margin)
        topBar.layoutParams = topBarParams
        val bottomBar = controls.findViewById<View>(R.id.bottom_bar)
        val bottomBarParams = bottomBar.layoutParams as android.widget.FrameLayout.LayoutParams
        bottomBarParams.bottomMargin = resources.getDimensionPixelSize(R.dimen.phone_player_bottom_bar_bottom_margin)
        bottomBar.layoutParams = bottomBarParams
    }

    private fun loadStream(
        url: String,
        headers: Map<String, String>,
        subs: List<MediaItem.SubtitleConfiguration>,
        mime: String?,
        positionMs: Long,
    ) {
        val p = player ?: return
        p.pause()
        playbackStarted = false
        subtitlePreferenceApplied = false
        currentUrl = url
        attemptedUrls.add(url)
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
        handler.removeCallbacks(startTimeout)
        handler.postDelayed(startTimeout, 30_000L)
    }

    private fun showEpisodeMenu() {
        if (episodeLabels.isEmpty()) return
        handler.removeCallbacks(hideRunnable) // a dialog must not race the auto-hide
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_title_episodes))
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
        resetZoom()
        val generation = ++mediaGeneration
        attemptedUrls.clear()
        val ch = PhonePlayerBridge.channel ?: return
        val p = player
        sendProgress()
        p?.pause() // don't leave the old episode running under the spinner
        playbackStarted = false
        handler.removeCallbacks(startTimeout)
        switching = true
        showLoading(episodeLabels.getOrNull(index))
        handler.postDelayed(resolveTimeout, 30_000L)
        ch.invokeMethod(
            "resolveEpisode",
            mapOf("index" to index),
            object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    val m = result as? Map<String, Any?>
                    if (generation != mediaGeneration) return
                    if (m == null) failSwitch() else applyResolved(index, m, generation)
                }
                override fun error(code: String, msg: String?, details: Any?) {
                    if (generation == mediaGeneration) failSwitch()
                }
                override fun notImplemented() {
                    if (generation == mediaGeneration) failSwitch()
                }
            },
        )
    }

    private fun failSwitch(message: String? = null) {
        switching = false
        handler.removeCallbacks(resolveTimeout)
        showLoadError(message ?: getString(R.string.phone_player_error_load))
    }

    private fun headersFrom(raw: Any?): Map<String, String> {
        val map = raw as? Map<*, *> ?: return emptyMap()
        val out = LinkedHashMap<String, String>()
        for ((key, value) in map) {
            if (key is String && value is String) out[key] = value
        }
        return out
    }

    @Suppress("UNCHECKED_CAST")
    private fun applyResolved(index: Int, m: Map<String, Any?>, generation: Int) {
        if (generation != mediaGeneration) return
        val url = m["url"] as? String
        if (url.isNullOrEmpty()) { failSwitch(); return }
        handler.removeCallbacks(resolveTimeout)
        currentIndex = index
        episodeText.text = m["episodeLabel"] as? String ?: episodeLabels.getOrNull(index) ?: ""
        loadingEpisode.text = episodeText.text
        setLoadingStatus(getString(R.string.phone_player_status_starting))
        updateEpisodeNavigation()
        loadStream(
            url = url,
            headers = headersFrom(m["headers"]),
            subs = subtitlesFrom(
                (m["subUrls"] as? List<String>) ?: emptyList(),
                (m["subLangs"] as? List<String>) ?: emptyList(),
                (m["subLabels"] as? List<String>) ?: emptyList(),
                (m["subFormats"] as? List<String>) ?: emptyList(),
                (m["subDefaults"] as? List<Boolean>) ?: emptyList(),
            ),
            mime = m["mimeType"] as? String,
            positionMs = (m["positionMs"] as? Number)?.toLong() ?: 0L,
        )
        switching = false // the new media's buffering drives the spinner now
        bumpControls()
    }

    private fun showSourceMenu() {
        val ch = PhonePlayerBridge.channel ?: return
        handler.removeCallbacks(hideRunnable)
        setBuffering(true)
        ch.invokeMethod(
            "sourcesFor",
            mapOf("index" to currentIndex),
            object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) {
                    if (!uiAlive()) return
                    setBuffering(false)
                    mirrors = mapList(result)
                    if (mirrors.isEmpty()) {
                        toast("Couldn't load sources")
                        bumpControls()
                        return
                    }
                    val labels = mirrors.mapIndexed { i, source ->
                        val label = (source["label"] as? String).orEmpty()
                            .ifBlank { "Server ${i + 1}" }
                        val quality = (source["quality"] as? String).orEmpty()
                        if (quality.isEmpty() || label.contains(quality)) label
                        else "$label · $quality"
                    }.toTypedArray()
                    val selected = mirrors.indexOfFirst { it["url"] == currentUrl }
                    android.app.AlertDialog.Builder(
                        this@PhonePlayerActivity,
                        R.style.PhonePlayerDialog,
                    )
                        .setTitle(getString(R.string.phone_player_title_sources))
                        .setSingleChoiceItems(labels, selected) { dialog, which ->
                            dialog.dismiss()
                            if (which != selected) playMirror(mirrors[which])
                        }
                        .setOnDismissListener { bumpControls() }
                        .show()
                }

                override fun error(code: String, msg: String?, details: Any?) {
                    if (!uiAlive()) return
                    setBuffering(false)
                    toast("Couldn't load sources")
                    bumpControls()
                }

                override fun notImplemented() {
                    if (!uiAlive()) return
                    setBuffering(false)
                    toast("Couldn't load sources")
                    bumpControls()
                }
            },
        )
    }

    private fun failover() {
        if (failoverInFlight) return
        val ch = PhonePlayerBridge.channel ?: run { finish(); return }
        failoverInFlight = true
        if (loadingOverlay.visibility == View.VISIBLE) {
            setLoadingStatus(getString(R.string.phone_player_status_retrying))
        } else {
            setBuffering(true)
        }
        val requestedIndex = currentIndex
        val requestedUrl = currentUrl
        val generation = mediaGeneration
        val position = player?.currentPosition ?: 0L
        ch.invokeMethod(
            "sourcesFor",
            mapOf("index" to currentIndex),
            object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) {
                    if (!uiAlive()) return
                    if (generation != mediaGeneration ||
                        requestedIndex != currentIndex ||
                        requestedUrl != currentUrl
                    ) {
                        failoverInFlight = false
                        return
                    }
                    failoverInFlight = false
                    mirrors = mapList(result)
                    val next = mirrors.firstOrNull { source ->
                        val url = source["url"] as? String
                        url != null && url !in attemptedUrls
                    }
                    if (next == null) {
                        failoverFailed()
                    } else {
                        playMirror(next, position, generation)
                    }
                }

                override fun error(code: String, msg: String?, details: Any?) {
                    if (!uiAlive()) return
                    if (generation != mediaGeneration) return
                    failoverFailed()
                }

                override fun notImplemented() {
                    if (!uiAlive()) return
                    if (generation != mediaGeneration) return
                    failoverFailed()
                }
            },
        )
    }

    private fun failoverFailed() {
        failoverInFlight = false
        if (playbackStarted) {
            toast("All sources failed")
            finish()
        } else {
            failSwitch(getString(R.string.phone_player_error_load))
        }
    }

    private fun mapList(result: Any?): List<Map<String, Any?>> {
        val list = result as? List<*> ?: return emptyList()
        return list.mapNotNull { item ->
            val map = item as? Map<*, *> ?: return@mapNotNull null
            map.entries.associate { (key, value) -> key.toString() to value }
        }
    }

    private fun uiAlive(): Boolean = !isFinishing && !isDestroyed

    private fun toast(message: String) {
        android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_SHORT).show()
    }

    @Suppress("UNCHECKED_CAST")
    private fun playMirror(
        m: Map<String, Any?>,
        positionMs: Long? = null,
        generation: Int? = null,
    ) {
        val url = m["url"] as? String ?: return
        if (generation == null) mediaGeneration++
        val keep = positionMs ?: (player?.currentPosition ?: 0L)
        loadStream(
            url = url,
            headers = headersFrom(m["headers"]),
            subs = subtitlesFrom(
                (m["subUrls"] as? List<String>) ?: emptyList(),
                (m["subLangs"] as? List<String>) ?: emptyList(),
                (m["subLabels"] as? List<String>) ?: emptyList(),
                (m["subFormats"] as? List<String>) ?: emptyList(),
                (m["subDefaults"] as? List<Boolean>) ?: emptyList(),
            ),
            mime = m["mimeType"] as? String,
            positionMs = keep,
        )
        if (loadingOverlay.visibility == View.VISIBLE) {
            setLoadingStatus(getString(R.string.phone_player_status_starting))
        }
    }

    /** Built from the player's own tracks: by now it knows about embedded
     *  text tracks Dart never saw. */
    private fun applySubtitlePreference(tracks: Tracks) {
        if (subtitlePreferenceApplied) return
        val p = player ?: return
        if (subtitlePreference.isEmpty()) {
            subtitlePreferenceApplied = true
            return
        }
        if (subtitlePreference == "off") {
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .build()
            subtitlePreferenceApplied = true
            return
        }
        for (group in tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }) {
            for (index in 0 until group.length) {
                val language = group.getTrackFormat(index).language
                if (languageMatches(language)) {
                    p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                        .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        .addOverride(TrackSelectionOverride(group.mediaTrackGroup, index))
                        .build()
                    subtitlePreferenceApplied = true
                    return
                }
            }
        }
    }

    private fun languageMatches(language: String?): Boolean {
        val candidate = language?.replace('_', '-')?.lowercase() ?: return false
        val wanted = subtitlePreference.replace('_', '-').lowercase()
        if (candidate == wanted || candidate.startsWith("$wanted-")) return true
        val wantedName = Locale.forLanguageTag(wanted)
            .getDisplayLanguage(Locale.getDefault())
        val candidateName = Locale.forLanguageTag(candidate)
            .getDisplayLanguage(Locale.getDefault())
        return wantedName.isNotEmpty() && candidateName.equals(wantedName, ignoreCase = true)
    }

    private fun showSubtitleMenu() {
        val p = player ?: return
        handler.removeCallbacks(hideRunnable)
        val groups = p.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
        val labels = mutableListOf("Off")
        val picks = mutableListOf<TrackSelectionOverride?>(null)
        for (g in groups) {
            for (i in 0 until g.length) {
                val f = g.getTrackFormat(i)
                labels += f.label ?: f.language ?: "Track ${labels.size}"
                picks += TrackSelectionOverride(g.mediaTrackGroup, i)
            }
        }
        if (labels.size == 1) {
            android.widget.Toast
                .makeText(this, "No subtitles in this stream", android.widget.Toast.LENGTH_SHORT)
                .show()
            bumpControls()
            return
        }
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_title_subtitles))
            .setItems(labels.toTypedArray()) { _, which ->
                selectTextTrack(picks[which])
            }
            .setOnDismissListener { bumpControls() }
            .show()
    }

    private fun showSpeedMenu() {
        val p = player ?: return
        handler.removeCallbacks(hideRunnable)
        val rates = floatArrayOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f, 2.5f, 3f, 4f, 5f)
        val checked = rates.indexOfFirst { kotlin.math.abs(it - p.playbackParameters.speed) < 0.001f }
        val labels = rates.map { "${it}x" }.toTypedArray()
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_title_speed))
            .setSingleChoiceItems(labels, checked) { dialog, which ->
                dialog.dismiss()
                p.playbackParameters = PlaybackParameters(rates[which])
                bumpControls()
            }
            .setOnDismissListener { bumpControls() }
            .show()
    }

    private fun selectAudioTrack(pick: TrackSelectionOverride?) {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
            .apply { if (pick != null) addOverride(pick) }
            .build()
        bumpControls()
    }

    private fun selectTextTrack(pick: TrackSelectionOverride?) {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, pick == null)
            .apply { if (pick != null) addOverride(pick) }
            .build()
        bumpControls()
    }

    private fun showTracksMenu() {
        val p = player ?: return
        handler.removeCallbacks(hideRunnable)
        val tracks = p.currentTracks
        val audio = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
        val text = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
        val audioTracks = audio.flatMap { g -> (0 until g.length).map { g to it } }
        val textTracks = text.flatMap { g -> (0 until g.length).map { g to it } }
        if (audioTracks.size + textTracks.size < 2) {
            toast(getString(R.string.phone_player_toast_no_tracks))
            bumpControls()
            return
        }
        val labels = mutableListOf("Audio: Auto")
        val audioPicks = mutableListOf<TrackSelectionOverride?>(null)
        for ((g, i) in audioTracks) {
            val f = g.getTrackFormat(i)
            labels += "Audio: ${f.label ?: f.language ?: "Track ${labels.size}"}"
            audioPicks += TrackSelectionOverride(g.mediaTrackGroup, i)
        }
        val textBase = labels.size
        labels += "Subtitles: Off"
        val textPicks = mutableListOf<TrackSelectionOverride?>(null)
        for ((g, i) in textTracks) {
            val f = g.getTrackFormat(i)
            labels += "Subtitles: ${f.label ?: f.language ?: "Track ${labels.size}"}"
            textPicks += TrackSelectionOverride(g.mediaTrackGroup, i)
        }
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_title_tracks))
            .setItems(labels.toTypedArray()) { _, which ->
                if (which < textBase) {
                    selectAudioTrack(audioPicks[which])
                } else {
                    selectTextTrack(textPicks[which - textBase])
                }
            }
            .setOnDismissListener { bumpControls() }
            .show()
    }

    private fun showQualityMenu() {
        val p = player ?: return
        handler.removeCallbacks(hideRunnable)
        val video = p.currentTracks.groups.filter { it.type == C.TRACK_TYPE_VIDEO }
        val videoTracks = video.flatMap { g -> (0 until g.length).map { g to it } }
        if (videoTracks.size < 2) {
            toast(getString(R.string.phone_player_toast_single_quality))
            bumpControls()
            return
        }
        val labels = mutableListOf("Auto")
        val picks = mutableListOf<TrackSelectionOverride?>(null)
        for ((g, i) in videoTracks.sortedByDescending { (g, i) -> g.getTrackFormat(i).height }) {
            val h = g.getTrackFormat(i).height
            labels += if (h > 0) "${h}p" else "Track ${labels.size}"
            picks += TrackSelectionOverride(g.mediaTrackGroup, i)
        }
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_title_quality))
            .setItems(labels.toTypedArray()) { _, which ->
                val pick = picks[which]
                p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                    .clearOverridesOfType(C.TRACK_TYPE_VIDEO)
                    .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, false)
                    .apply { if (pick != null) addOverride(pick) }
                    .build()
                bumpControls()
            }
            .setOnDismissListener { bumpControls() }
            .show()
    }

    private fun toggleRotation() {
        requestedOrientation = if (requestedOrientation == ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE) {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        bumpControls()
    }

    private fun showDisplayMenu() {
        handler.removeCallbacks(hideRunnable)
        val modes = intArrayOf(
            AspectRatioFrameLayout.RESIZE_MODE_FIT,
            AspectRatioFrameLayout.RESIZE_MODE_FILL,
            AspectRatioFrameLayout.RESIZE_MODE_ZOOM
        )
        val labels = arrayOf(
            getString(R.string.phone_player_mode_fit),
            getString(R.string.phone_player_mode_fill),
            getString(R.string.phone_player_mode_zoom)
        )
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_menu_display))
            .setSingleChoiceItems(labels, resizeIndex) { dialog, which ->
                dialog.dismiss()
                resizeIndex = which
                playerView.resizeMode = modes[which]
                bumpControls()
            }
            .setOnDismissListener { bumpControls() }
            .show()
    }

    private fun pickCast() {
        castManager?.pickDevice()
        bumpControls()
    }

    private fun showMoreMenu() {
        handler.removeCallbacks(hideRunnable)
        val labels = mutableListOf(
            getString(R.string.phone_player_title_speed),
            getString(R.string.phone_player_title_tracks),
            getString(R.string.phone_player_title_quality),
            getString(R.string.phone_player_menu_sources),
            getString(R.string.phone_player_menu_episodes),
            getString(R.string.phone_player_menu_display),
            getString(R.string.phone_player_menu_rotate)
        )
        val icons = mutableListOf(
            R.drawable.phone_player_speed,
            R.drawable.phone_player_tracks,
            R.drawable.phone_player_quality,
            R.drawable.phone_player_sources,
            R.drawable.phone_player_episodes,
            R.drawable.phone_player_display,
            R.drawable.phone_player_rotate
        )
        val actions = mutableListOf<() -> Unit>(
            { showSpeedMenu() },
            { showTracksMenu() },
            { showQualityMenu() },
            { showSourceMenu() },
            { showEpisodeMenu() },
            { showDisplayMenu() },
            { toggleRotation() }
        )
        if (castSupported) {
            labels += getString(R.string.phone_player_menu_cast)
            icons += R.drawable.phone_player_cast
            actions += { pickCast() }
        }
        labels += getString(R.string.phone_player_menu_info)
        icons += R.drawable.phone_player_info
        actions += { showInfo() }
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density + 0.5f).toInt()
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val surfaceColor = getColor(R.color.phone_player_surface)
        val textColor = getColor(R.color.phone_player_on_surface)
        val mutedColor = getColor(R.color.phone_player_on_surface_variant)
        val dialog = android.app.Dialog(this, R.style.PhonePlayerDialog)
        dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        val sheet = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(dp(18), dp(14), dp(18), dp(18))
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(surfaceColor)
                val radius = dp(28).toFloat()
                cornerRadii = if (landscape) {
                    floatArrayOf(radius, radius, 0f, 0f, 0f, 0f, radius, radius)
                } else {
                    floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
                }
            }
        }
        val header = android.widget.LinearLayout(this).apply {
            gravity = android.view.Gravity.CENTER_VERTICAL
            orientation = android.widget.LinearLayout.HORIZONTAL
        }
        header.addView(android.widget.TextView(this).apply {
            text = getString(R.string.phone_player_title_more)
            textSize = 22f
            gravity = android.view.Gravity.CENTER_VERTICAL
            setTextColor(textColor)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }, android.widget.LinearLayout.LayoutParams(0, dp(52), 1f))
        header.addView(android.widget.ImageView(this).apply {
            setImageResource(R.drawable.phone_player_close)
            background = getDrawable(R.drawable.phone_player_action_surface)
            clipToOutline = true
            foreground = getDrawable(R.drawable.phone_player_icon_ripple)
            contentDescription = getString(android.R.string.cancel)
            isClickable = true
            isFocusable = true
            setPadding(dp(11), dp(11), dp(11), dp(11))
            setOnClickListener { dialog.dismiss() }
        }, android.widget.LinearLayout.LayoutParams(dp(42), dp(42)))
        sheet.addView(header)

        val list = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
        }
        for (index in labels.indices) {
            val group = when (index) {
                0 -> "PLAYBACK"
                3 -> "WATCH NEXT"
                5 -> "SCREEN & DEVICE"
                else -> null
            }
            if (group != null) {
                list.addView(android.widget.TextView(this).apply {
                    text = group
                    textSize = 11f
                    letterSpacing = 0.12f
                    setTextColor(getColor(R.color.phone_player_accent))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setPadding(dp(12), dp(14), 0, dp(5))
                })
            }
            val row = android.widget.LinearLayout(this).apply {
                gravity = android.view.Gravity.CENTER_VERTICAL
                minimumHeight = dp(54)
                orientation = android.widget.LinearLayout.HORIZONTAL
                setPadding(dp(14), dp(8), dp(14), dp(8))
                background = getDrawable(R.drawable.phone_player_action_surface)
                clipToOutline = true
                foreground = getDrawable(R.drawable.phone_player_icon_ripple)
                isClickable = true
                isFocusable = true
                contentDescription = labels[index]
                setOnClickListener {
                    dialog.dismiss()
                    actions[index]()
                }
            }
            row.addView(android.widget.ImageView(this).apply {
                setImageResource(icons[index])
                imageTintList = android.content.res.ColorStateList.valueOf(mutedColor)
            }, android.widget.LinearLayout.LayoutParams(dp(24), dp(24)))
            row.addView(android.widget.TextView(this).apply {
                text = labels[index]
                textSize = 15f
                setTextColor(textColor)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            }, android.widget.LinearLayout.LayoutParams(0, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(14)
            })
            row.addView(android.widget.TextView(this).apply {
                text = "›"
                textSize = 23f
                setTextColor(mutedColor)
            })
            list.addView(row, android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(6) })
        }
        sheet.addView(android.widget.ScrollView(this).apply {
            isFillViewport = false
            addView(list)
        }, android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
            0,
            1f,
        ))
        dialog.setContentView(sheet)
        dialog.setOnDismissListener {
            moreDialog = null
            bumpControls()
        }
        moreDialog = dialog
        dialog.show()
        dialog.window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(0.56f)
            setGravity(if (landscape) android.view.Gravity.END else android.view.Gravity.BOTTOM)
            setLayout(
                if (landscape) dp(370) else WindowManager.LayoutParams.MATCH_PARENT,
                if (landscape) WindowManager.LayoutParams.MATCH_PARENT
                else (resources.displayMetrics.heightPixels * 0.78f).toInt(),
            )
        }
    }

    private fun showInfo() {
        handler.removeCallbacks(hideRunnable)
        val p = player
        val pos = p?.currentPosition ?: 0L
        val dur = p?.duration ?: 0L
        val speed = p?.playbackParameters?.speed
            ?: intent.getFloatExtra(PhonePlayerIntent.EXTRA_SPEED, 1f)
        val mirrorLabel = mirrors.firstOrNull { it["url"] == currentUrl }
            ?.get("label") as? String
        val source = if (!mirrorLabel.isNullOrBlank()) {
            mirrorLabel
        } else {
            runCatching { android.net.Uri.parse(currentUrl).host ?: currentUrl }
                .getOrDefault(currentUrl)
        }
        val message = listOf(
            titleText.text.toString(),
            episodeText.text.toString(),
            "${fmt(pos)} / ${fmt(dur)}",
            source,
            "${speed}x",
        ).filter { it.isNotEmpty() }.joinToString("\n")
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_title_playback_info))
            .setMessage(message)
            .setPositiveButton(android.R.string.ok, null)
            .setOnDismissListener { bumpControls() }
            .show()
    }

    private fun updateKeepScreenOn() {
        val active = player?.let {
            it.isPlaying || it.playbackState == Player.STATE_BUFFERING
        } == true
        if (keepScreenOn && active) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    /** Activity-only event: it never writes history or changes the player. */
    private fun sendDiscordPresence() {
        val p = player ?: return
        if (reported || !playbackStarted || p.duration <= 0) return
        PhonePlayerBridge.channel?.invokeMethod(
            "discordPresence",
            mapOf(
                "index" to currentIndex,
                "positionMs" to p.currentPosition.coerceAtLeast(0L),
                "durationMs" to p.duration,
                "playing" to (p.playWhenReady && p.playbackState != Player.STATE_ENDED),
            ),
        )
    }

    private fun sendProgress() {
        val p = player ?: return
        if (!playbackStarted || p.duration <= 0) return
        PhonePlayerBridge.channel?.invokeMethod(
            "saveProgress",
            mapOf(
                "index" to currentIndex,
                "positionMs" to p.currentPosition.coerceAtLeast(0L),
                "durationMs" to p.duration.coerceAtLeast(0L),
            ),
        )
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

    // ── Gesture overlays + handling (MPV parity, Views only) ──────────────

    /** Pill, time bubble and double-tap labels. Built in code so no layout
     * file changes; all translucent dark like the chrome scrims. */
    private fun createGestureOverlays() {
        val root = findViewById<ViewGroup>(R.id.player_root)
        val density = resources.displayMetrics.density
        fun pill(): android.graphics.drawable.GradientDrawable =
            android.graphics.drawable.GradientDrawable().apply {
                shape = android.graphics.drawable.GradientDrawable.RECTANGLE
                cornerRadius = 20f * density
                setColor(0xCC0B0B0FL.toInt())
            }

        hudPill =
            LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = pill()
                setPadding(
                    (14 * density).toInt(),
                    (10 * density).toInt(),
                    (14 * density).toInt(),
                    (10 * density).toInt(),
                )
                visibility = View.GONE
            }
        hudLabel =
            TextView(this).apply {
                setTextColor(0xFFF9F4F5L.toInt())
                textSize = 13f
                typeface = android.graphics.Typeface.MONOSPACE
                minWidth = (64 * density).toInt()
            }
        hudBar =
            ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
                max = 100
                layoutParams =
                    LinearLayout.LayoutParams((110 * density).toInt(), (4 * density).toInt()).apply {
                        marginStart = (10 * density).toInt()
                    }
                progressTintList = ColorStateList.valueOf(0xFFFF626DL.toInt())
                progressBackgroundTintList = ColorStateList.valueOf(0x40FFFFFFL.toInt())
            }
        hudPill.addView(hudLabel)
        hudPill.addView(hudBar)
        root.addView(
            hudPill,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL,
            ).apply { topMargin = (72 * density).toInt() },
        )

        seekBubble =
            TextView(this).apply {
                setTextColor(0xFFF9F4F5L.toInt())
                textSize = 14f
                typeface = android.graphics.Typeface.MONOSPACE
                background = pill()
                setPadding(
                    (14 * density).toInt(),
                    (8 * density).toInt(),
                    (14 * density).toInt(),
                    (8 * density).toInt(),
                )
                visibility = View.GONE
            }
        root.addView(
            seekBubble,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL,
            ).apply { topMargin = (72 * density).toInt() },
        )

        fun seekLabel(): TextView =
            TextView(this).apply {
                setTextColor(0xFFFFFFFFL.toInt())
                textSize = 22f
                typeface = android.graphics.Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                visibility = View.GONE
            }
        dblLeft = seekLabel()
        dblRight = seekLabel()
        root.addView(
            dblLeft,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_VERTICAL or Gravity.START,
            ).apply { marginStart = (64 * density).toInt() },
        )
        root.addView(
            dblRight,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_VERTICAL or Gravity.END,
            ).apply { marginEnd = (64 * density).toInt() },
        )
    }

    /** Routes a touch to swipe/pinch handling, falling back to the tap
     * detector only while no custom gesture owns the stream. */
    private fun handlePlayerTouch(
        v: View,
        ev: MotionEvent,
        taps: android.view.GestureDetector,
    ) {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pointers.clear()
                pointers[ev.getPointerId(0)] = ev.x to ev.y
                downX = ev.x
                downY = ev.y
                gestureMode = 0
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                pointers[ev.getPointerId(ev.actionIndex)] = ev.getX(ev.actionIndex) to ev.getY(ev.actionIndex)
                if (pointers.size == 2) startPinch()
            }
            MotionEvent.ACTION_MOVE -> {
                val id = ev.getPointerId(0)
                if (pointers.containsKey(id)) pointers[id] = ev.x to ev.y
                for (i in 1 until ev.pointerCount) {
                    pointers[ev.getPointerId(i)] = ev.getX(i) to ev.getY(i)
                }
                if (pinchActive && pointers.size >= 2) {
                    updatePinch()
                } else if (gestureMode == 0 && pointers.size == 1) {
                    val dx = ev.x - downX
                    val dy = ev.y - downY
                    val slop = 24f * resources.displayMetrics.density
                    if (kotlin.math.max(kotlin.math.abs(dx), kotlin.math.abs(dy)) > slop) {
                        gestureMode = if (kotlin.math.abs(dx) > kotlin.math.abs(dy)) 1 else 2
                        if (gestureMode == 1) startHSeek() else startVSlide(ev.x)
                    }
                } else if (gestureMode == 1) {
                    updateHSeek(ev.x)
                } else if (gestureMode == 2) {
                    updateVSlide(ev.y)
                }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                pointers.remove(ev.getPointerId(ev.actionIndex))
                if (pinchActive && pointers.size < 2) endPinch()
                // The remaining finger starts fresh so its drift can't inherit
                // the pinch's travel as a swipe.
                if (pointers.size == 1) {
                    val (_, p) = pointers.entries.first()
                    downX = p.first
                    downY = p.second
                    gestureMode = 0
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (gestureMode == 1 && ev.actionMasked == MotionEvent.ACTION_UP) commitHSeek()
                if (gestureMode == 2) endVSlide()
                if (pinchActive) endPinch()
                pointers.clear()
                gestureMode = 0
                // Only a real release is a "click"; firing on every ACTION_MOVE
                // spams TalkBack with a click event per drag sample.
                if (ev.actionMasked == MotionEvent.ACTION_UP) v.performClick()
            }
        }
        if (!pinchActive && gestureMode == 0 &&
            android.os.SystemClock.uptimeMillis() - pinchEndAt > 300L
        ) {
            taps.onTouchEvent(ev)
        }
    }

    /** Accumulating double-tap label, Dantotsu-style: "-20s", "+30s". */
    private fun flashSeekLabel(dir: Int) {
        if (dir < 0) {
            dblAccumL -= seekMs
            dblLeft.text = "-${dblAccumL / 1000}s"
            dblLeft.visibility = View.VISIBLE
            dblLeft.alpha = 1f
        } else {
            dblAccumR += seekMs
            dblRight.text = "+${dblAccumR / 1000}s"
            dblRight.visibility = View.VISIBLE
            dblRight.alpha = 1f
        }
        handler.removeCallbacks(resetDbl)
        handler.postDelayed(resetDbl, 800L)
    }

    // ── Horizontal scrub: full width maps to the whole duration ────────────
    private fun startHSeek() {
        val p = player ?: return
        if (p.duration <= 0) {
            gestureMode = 0
            return
        }
        hSeekBase = p.currentPosition
        hSeekTarget = hSeekBase
        handler.removeCallbacks(hideHud)
        updateSeekBubble()
    }

    private fun updateHSeek(x: Float) {
        val p = player ?: return
        val d = p.duration
        if (d <= 0) return
        val perPx = d.toFloat() / vWidth()
        hSeekTarget = (hSeekBase + (x - downX) * perPx).toLong().coerceIn(0L, d)
        updateSeekBubble()
    }

    private fun updateSeekBubble() {
        val delta = (hSeekTarget - hSeekBase) / 1000
        val sign = if (delta >= 0) "+" else "-"
        seekBubble.text = "${fmt(hSeekTarget)}  ($sign${kotlin.math.abs(delta)}s)"
        seekBubble.visibility = View.VISIBLE
    }

    private fun commitHSeek() {
        player?.seekTo(hSeekTarget)
        seekBubble.visibility = View.GONE
        bumpControls()
    }

    // ── Vertical slide: left = brightness, right = volume (MX-style) ───────
    private fun startVSlide(x: Float) {
        val w = vWidth()
        if (w <= 0) {
            gestureMode = 0
            return
        }
        vIsBrightness = x < w / 2f
        lastHudPct = -1
        vStart =
            if (vIsBrightness) {
                val attr = window.attributes.screenBrightness
                if (attr >= 0) attr else systemBrightness()
            } else {
                val audio = getSystemService(AUDIO_SERVICE) as AudioManager
                audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() /
                    audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
            }
        handler.removeCallbacks(hideHud)
    }

    private fun systemBrightness(): Float =
        runCatching {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f
        }.getOrDefault(0.5f)

    private fun updateVSlide(y: Float) {
        val h = vHeight()
        if (h <= 0) return
        // Drag up (negative delta) raises the value; ~70% of the height spans
        // the full range, same feel as the MPV player.
        val v = (vStart + (downY - y) / (h * 0.7f)).coerceIn(0f, 1f)
        if (vIsBrightness) {
            val lp = window.attributes
            lp.screenBrightness = v
            window.attributes = lp
        } else {
            val audio = getSystemService(AUDIO_SERVICE) as AudioManager
            audio.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                kotlin.math.max(0, Math.round(v * audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC))),
                0, // no OS volume popup; the HUD below says it instead
            )
        }
        val pct = Math.round(v * 100)
        hudLabel.text = (if (vIsBrightness) "☀ " else "♫ ") + "$pct%"
        hudBar.progress = pct
        hudPill.visibility = View.VISIBLE
        // Haptic tick on the landmarks, like the MPV player.
        val marks = if (vIsBrightness) intArrayOf(0, 50, 100) else intArrayOf(0, 100)
        if (lastHudPct >= 0) {
            for (b in marks) {
                if ((lastHudPct - b) * (pct - b) <= 0 && lastHudPct != pct) {
                    hudPill.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    break
                }
            }
        }
        lastHudPct = pct
    }

    private fun endVSlide() {
        handler.removeCallbacks(hideHud)
        handler.postDelayed(hideHud, 500L)
    }

    // ── Pinch-to-zoom on the TextureView ────────────────────────────────────
    private fun resetZoom() {
        zoom = 1f
        panX = 0f
        panY = 0f
        pinchActive = false
        val tex = textureView() ?: return
        tex.setTransform(Matrix())
        tex.invalidate()
    }

    private fun textureView(): TextureView? =
        runCatching { playerView.videoSurfaceView as? TextureView }.getOrNull()

    private fun startPinch() {
        if (textureView() == null) return
        // A pinch cancels any swipe in flight; the scrub never commits.
        if (gestureMode == 1) seekBubble.visibility = View.GONE
        gestureMode = 0
        val pts = pointers.values.toList()
        pinchBaseSpan = span(pts[0], pts[1])
        pinchBaseZoom = zoom
        pinchActive = pinchBaseSpan > 0f
    }

    private fun updatePinch() {
        val tex = textureView() ?: return
        val pts = pointers.values.toList()
        if (pts.size < 2 || pinchBaseSpan <= 0f) return
        val w = tex.width.toFloat()
        val h = tex.height.toFloat()
        if (w <= 0f || h <= 0f) return
        val newZoom = (pinchBaseZoom * span(pts[0], pts[1]) / pinchBaseSpan).coerceIn(1f, 4f)
        if (newZoom > 1f) {
            // Focal-anchored: the content point under the fingers stays put,
            // so the video grows around your grip instead of sliding away.
            val f = focal(pts[0], pts[1])
            val ratio = newZoom / zoom.coerceAtLeast(1f)
            panX = f.first - (f.first - panX) * ratio
            panY = f.second - (f.second - panY) * ratio
            val maxX = w * (newZoom - 1f) / 2f
            val maxY = h * (newZoom - 1f) / 2f
            panX = panX.coerceIn(-maxX, maxX)
            panY = panY.coerceIn(-maxY, maxY)
        } else {
            panX = 0f
            panY = 0f
        }
        zoom = newZoom
        val m = Matrix()
        m.postTranslate(-w / 2f, -h / 2f)
        m.postScale(zoom, zoom)
        m.postTranslate(w / 2f + panX, h / 2f + panY)
        tex.setTransform(m)
        tex.invalidate()
    }

    private fun endPinch() {
        pinchActive = false
        pinchEndAt = android.os.SystemClock.uptimeMillis()
        if (zoom <= 1.05f) resetZoom()
        // Let a lingering finger start over instead of inheriting travel.
        if (pointers.size == 1) {
            val (_, p) = pointers.entries.first()
            downX = p.first
            downY = p.second
        }
        gestureMode = 0
    }

    private fun span(a: Pair<Float, Float>, b: Pair<Float, Float>): Float =
        kotlin.math.hypot((a.first - b.first).toDouble(), (a.second - b.second).toDouble()).toFloat()

    private fun focal(a: Pair<Float, Float>, b: Pair<Float, Float>): Pair<Float, Float> =
        (a.first + b.first) / 2f to (a.second + b.second) / 2f

    private fun vWidth(): Float = findViewById<View>(R.id.player_root).width.toFloat()

    private fun vHeight(): Float = findViewById<View>(R.id.player_root).height.toFloat()

    private fun syncPlayIcon() {
        val playing = player?.isPlaying == true
        btnPlay.contentDescription = if (playing) getString(R.string.phone_player_state_pause) else getString(R.string.phone_player_state_play)
        val resource = if (playing) R.drawable.ic_pip_pause else R.drawable.ic_pip_play
        if (btnPlay.tag == resource) return
        btnPlay.tag = resource
        val interpolator = android.view.animation.AnimationUtils.loadInterpolator(
            this,
            android.R.interpolator.fast_out_slow_in
        )
        btnPlay.animate().cancel()
        btnPlay.animate()
            .alpha(0f)
            .scaleX(0.7f)
            .scaleY(0.7f)
            .setDuration(120L)
            .setInterpolator(interpolator)
            .withEndAction {
                if (btnPlay.tag != resource) return@withEndAction
                btnPlay.setImageResource(resource)
                btnPlay.animate()
                    .alpha(1f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .setDuration(150L)
                    .setInterpolator(interpolator)
                    .start()
            }
            .start()
    }

    private fun syncProgress() {
        val p = player ?: return
        val d = p.duration
        if (d > 0) {
            val pos = p.currentPosition
            durationText.text = fmt(d)
            if (!scrubbing) {
                val progress = (pos * 1000 / d).toInt().coerceIn(0, 1000)
                if (android.os.Build.VERSION.SDK_INT >= 24) {
                    seek.setProgress(progress, true)
                } else {
                    seek.progress = progress
                }
                positionText.text = fmt(pos)
                seek.contentDescription = getString(R.string.phone_player_desc_seek) + ", " + fmt(pos) + " of " + fmt(d)
            }
        }
    }

    private fun restoreControls() {
        controlsHiding = false
        controls.animate().cancel()
        controls.visibility = View.VISIBLE
        controls.alpha = 1f
        controls.scaleX = 1f
        controls.scaleY = 1f
    }

    private fun showControls() {
        controlsHiding = false
        controls.animate().cancel()
        controls.visibility = View.VISIBLE
        if (controls.width > 0 && controls.height > 0) {
            controls.pivotX = controls.width / 2f
            controls.pivotY = controls.height / 2f
        }
        controls.alpha = 0f
        controls.scaleX = 0.96f
        controls.scaleY = 0.96f
        controls.animate()
            .alpha(1f)
            .scaleX(1f)
            .scaleY(1f)
            .setDuration(250L)
            .setInterpolator(
                android.view.animation.AnimationUtils.loadInterpolator(
                    this,
                    android.R.interpolator.fast_out_slow_in
                )
            )
            .start()
        syncPlayIcon()
        syncProgress()
        bumpControls()
    }

    private fun hideControls() {
        if (scrubbing) return
        controlsHiding = true
        controls.animate().cancel()
        if (controls.width > 0 && controls.height > 0) {
            controls.pivotX = controls.width / 2f
            controls.pivotY = controls.height / 2f
        }
        controls.animate()
            .alpha(0f)
            .scaleX(0.96f)
            .scaleY(0.96f)
            .setDuration(200L)
            .setInterpolator(
                android.view.animation.AnimationUtils.loadInterpolator(
                    this,
                    android.R.interpolator.linear_out_slow_in
                )
            )
            .withEndAction {
                if (controlsHiding && controls.alpha == 0f) {
                    controls.visibility = View.GONE
                    controlsHiding = false
                }
            }
            .start()
        handler.removeCallbacks(hideRunnable)
    }

    /** Restart the auto-hide countdown; paused playback keeps the bar up. */
    private fun bumpControls() {
        if (controlsHiding) restoreControls()
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
        (intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_SUB_FORMATS) ?: emptyArray()).toList(),
        (intent.getBooleanArrayExtra(PhonePlayerIntent.EXTRA_SUB_DEFAULTS) ?: BooleanArray(0)).toList(),
    )

    private fun subtitlesFrom(
        urls: List<String>,
        langs: List<String>,
        labels: List<String>,
        formats: List<String>,
        defaults: List<Boolean>,
    ): List<MediaItem.SubtitleConfiguration> {
        val defaultIndex = defaults.indexOfFirst { it }
        val fallbackIndex = if (urls.isEmpty()) -1 else 0
        val selectedDefault = if (defaultIndex >= 0) defaultIndex else fallbackIndex
        return urls.mapIndexedNotNull { i, rawUrl ->
            if (rawUrl.isEmpty()) return@mapIndexedNotNull null
            val format = formats.getOrNull(i).orEmpty()
            MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(rawUrl))
                .setMimeType(subtitleMime(format, rawUrl))
                .setLanguage(langs.getOrNull(i))
                .setLabel(labels.getOrNull(i))
                .setSelectionFlags(if (i == selectedDefault) C.SELECTION_FLAG_DEFAULT else 0)
                .build()
        }
    }

    private fun subtitleMime(format: String, url: String): String {
        val f = format.lowercase()
        val u = url.lowercase()
        return when {
            f == "vtt" || f == "webvtt" -> MimeTypes.TEXT_VTT
            f == "ass" || f == "ssa" -> MimeTypes.TEXT_SSA
            f == "ttml" || f == "dfxp" -> "application/ttml+xml"
            f == "srt" || f == "subrip" -> MimeTypes.APPLICATION_SUBRIP
            u.contains(".vtt") -> MimeTypes.TEXT_VTT
            u.contains(".ass") || u.contains(".ssa") -> MimeTypes.TEXT_SSA
            u.contains(".ttml") || u.contains(".dfxp") -> "application/ttml+xml"
            u.contains(".srt") -> MimeTypes.APPLICATION_SUBRIP
            else -> MimeTypes.TEXT_VTT
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
        sendProgress()
        player?.pause()
        updateKeepScreenOn()
        handler.removeCallbacks(ticker)
    }

    // The ticker is stopped in onPause so it doesn't keep polling a paused
    // player and writing to invisible views while backgrounded; restart it
    // here rather than in onCreate.
    override fun onResume() {
        super.onResume()
        updateKeepScreenOn()
        handler.post(ticker)
    }

    override fun onDestroy() {
        reportClosed()
        handler.removeCallbacksAndMessages(null)
        moreDialog?.setOnDismissListener(null)
        moreDialog?.dismiss()
        moreDialog = null
        active = null
        castManager?.release()
        castManager = null
        player?.release()
        player = null
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (loadingActions.visibility == View.VISIBLE) { finish(); return }
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
