package com.spyou.watch_app

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Matrix
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.ViewStub
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
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
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
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
        private const val ROTATION_PULL_DISTANCE_DP = 64

        internal fun megaSkipTarget(position: Long, duration: Long, seconds: Int): Long? {
            if (duration <= 0) return null
            val start = position.coerceIn(0L, duration)
            return start + minOf(seconds.coerceIn(5, 180) * 1000L, duration - start)
        }

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
    private lateinit var loadingActions: View
    private lateinit var loadingTitlePulse: PlaybackTitlePulse

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
    private lateinit var seekPreview: PhoneSeekPreview
    private lateinit var timeText: android.widget.TextView
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
    private var gestureMode = 0 // 0 idle, 1 horizontal scrub, 2 vertical slide, 3 rotate
    private var singleFingerRotation = false
    private var rotationDownX = 0f
    private var rotationDownY = 0f
    private var speedBeforeHold: PlaybackParameters? = null
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
    private lateinit var holdSpeedBadge: TextView
    private lateinit var rotationPullHint: LinearLayout
    private lateinit var rotationPullArrow: TextView
    private lateinit var rotationPullProgress: ProgressBar
    private lateinit var dblLeft: TextView
    private lateinit var dblRight: TextView

    private var lastPresenceAt = 0L
    private val ticker = object : Runnable {
        override fun run() {
            syncProgress()
            // A slow heartbeat keeps live tracking (Simkl) advancing during
            // continuous playback; events alone only report the first second.
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastPresenceAt >= 10_000L) {
                lastPresenceAt = now
                if (player?.isPlaying == true) sendDiscordPresence()
            }
            handler.postDelayed(this, 250L)
        }
    }

    private data class SkipSegment(val start: Long, val end: Long, val label: Int, val auto: Boolean)

    private lateinit var segmentButton: FrameLayout
    private lateinit var segmentLabel: TextView
    private lateinit var segmentFill: TextView
    private var segmentProgress = 0
    private val segmentTimer by lazy {
        android.animation.ValueAnimator.ofInt(0, 10_000).apply {
            duration = 10_000L
            interpolator = android.view.animation.LinearInterpolator()
            addUpdateListener {
                val progress = it.animatedValue as Int
                segmentProgress = progress
                updateSegmentFill()
                if (progress == 10_000 && !segmentControlsVisible()) {
                    segmentButton.visibility = View.GONE
                }
            }
        }
    }
    private var activeSegment: SkipSegment? = null
    private var skipSegments = emptyList<SkipSegment>()
    private var showSegmentButton = false
    private var skipsRequested = false
    private val autoSkipped = mutableSetOf<Long>()

    private var currentIndex = 0
    // The selected episode can change while the previous stream is still loaded.
    private var loadedEpisodeIndex = 0
    /** True once the first stream has produced frames: later episode taps
     * resolve inside the miniplayer instead of the fullscreen loader. */
    private var everPlayed = false
    private var playbackError = false
    private var reported = false

    // ── Portrait watch page ──────────────────────────────────────────────
    // Same session concept as the Flutter page: the video+controls area
    // (player_root) stays the live player; the info panel below is
    // presentation only. Fullscreen (landscape) hides the panel and expands
    // the same container — ExoPlayer and PlayerView are never rebuilt.
    var sessionId = 0L
        private set
    private var playerOrientation = "landscape"
    private var watchPage = false
    private var orientationObserver: PhoneOrientationObserver? = null
    private var categories: List<String> = emptyList()
    private var currentCategory = "sub"
    private var pendingDesc: String? = null
    private var descExpanded = false
    private var watchInfo: ViewGroup? = null
    private var watchPanel: PhoneWatchPage? = null

    private var episodeCount = 1
    private var episodeLabels: Array<String> = emptyArray()
    private var isMovie = false
    private var switching = false
    private var mediaGeneration = 0
    private var failoverInFlight = false
    private var engineFallbackRequested = false
    private val pip by lazy { PipController(this) }
    private var autoPipEnabled = false
    private var currentUrl = ""
    private val attemptedUrls = mutableSetOf<String>()
    private var refreshedForbiddenLinks = false
    private var autoplayNext = true
    private var ambientEnabled = true
    private var seekMs = 10_000L
    private var megaSkipEnabled = true
    private var megaSkipSeconds = 85
    private var keepScreenOn = true
    private var subtitlePreference = ""
    private var subtitleScale = 1f
    private var subtitlePosition = 95
    private var subtitleBackground = android.graphics.Color.TRANSPARENT
    private var subtitleForeground = android.graphics.Color.WHITE
    private var subtitleEdgeType = CaptionStyleCompat.EDGE_TYPE_OUTLINE
    private var subtitleEdgeColor = android.graphics.Color.BLACK
    private var subtitleFontPath: String? = null
    private var subtitleTypeface: android.graphics.Typeface? = null
    private var subtitleStyleDialog: android.app.Dialog? = null
    private var subtitlePreferenceApplied = false
    private var pendingAddonSubtitleId: String? = null
    private var currentSourceFactory: DefaultMediaSourceFactory? = null
    private var playbackDiskCache: androidx.media3.datasource.cache.Cache? = null
    private var playbackStarted = false
    private var resizeIndex = 0
    private var controlLayout = PhonePlayerControlLayout()
    private var controlsLocked = false
    private var unlockControl: View? = null
    private val controlIconFont by lazy {
        runCatching {
            android.graphics.Typeface.createFromAsset(assets, "flutter_assets/fonts/MaterialIcons-Regular.otf")
        }.getOrNull()
    }

    private var mirrors: List<Map<String, Any?>> = emptyList()
    private var castManager: CastManager? = null
    private var castSupported = false
    private var episodePanel: PhoneEpisodePanel? = null
    private var moreDialog: android.app.Dialog? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        controlLayout = PhonePlayerControlLayout.fromJson(intent.getStringExtra(PhonePlayerIntent.EXTRA_CONTROLS))
        megaSkipEnabled = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_MEGA_SKIP, true)
        megaSkipSeconds = intent.getIntExtra(PhonePlayerIntent.EXTRA_MEGA_SKIP_SECONDS, 85).coerceIn(5, 180)
        keepScreenOn = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_KEEP_SCREEN_ON, true)
        autoPipEnabled = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_AUTO_PIP, false)
        pip.onControl = { control ->
            when (control) {
                PipController.PLAY_PAUSE -> togglePlay()
                PipController.REWIND -> player?.seekTo(((player?.currentPosition ?: 0L) - 10_000L).coerceAtLeast(0L))
                PipController.FORWARD -> player?.seekTo((player?.currentPosition ?: 0L) + 10_000L)
            }
        }
        pip.autoEnter = autoPipEnabled
        pip.register()
        sessionId = intent.getLongExtra(PhonePlayerIntent.EXTRA_SESSION, 0L)
        playerOrientation = when (intent.getStringExtra(PhonePlayerIntent.EXTRA_ORIENTATION)) {
            "portrait" -> "portrait"
            "system" -> "system"
            else -> "landscape"
        }
        watchPage = playerOrientation == "portrait" ||
            (playerOrientation == "system" &&
                resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT)
        categories = intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_CATEGORIES)?.toList() ?: emptyList()
        currentCategory = intent.getStringExtra(PhonePlayerIntent.EXTRA_CATEGORY) ?: "sub"
        pendingDesc = intent.getStringExtra(PhonePlayerIntent.EXTRA_SHOW_DESC)
        // Set before inflation so the activity starts in the selected phone orientation.
        requestedOrientation = when (playerOrientation) {
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "system" -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            else -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        if (playerOrientation == "system") {
            orientationObserver = PhoneOrientationObserver(this) {
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            }
        }
        if (keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        goImmersive()

        val url = intent.getStringExtra(PhonePlayerIntent.EXTRA_URL).orEmpty()

        setContentView(R.layout.phone_player)
        playerView = findViewById(R.id.player_view)
        playerView.keepSubtitlesInViewport()
        fun label(color: Int) = TextView(this).apply {
            gravity = Gravity.CENTER
            minHeight = dp(44)
            setPadding(dp(14), 0, dp(14), 0)
            textSize = 13f
            setTextColor(color)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        segmentLabel = label(android.graphics.Color.WHITE)
        segmentFill = label(android.graphics.Color.BLACK).apply {
            setBackgroundColor(android.graphics.Color.WHITE)
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateSegmentFill() }
        }
        segmentButton = FrameLayout(this).apply {
            visibility = View.GONE
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(0xC2000000.toInt())
                cornerRadius = dp(22).toFloat()
            }
            clipToOutline = true
            isFocusable = true
            addView(segmentLabel, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
            addView(segmentFill, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
            ))
            setOnClickListener {
                val segment = activeSegment ?: return@setOnClickListener
                autoSkipped.add(segment.start)
                player?.seekTo(segment.end)
                updateSegmentButton(null)
            }
        }
        val stage = findViewById<FrameLayout>(R.id.player_root)
        stage.addView(segmentButton, stage.indexOfChild(findViewById<View>(R.id.loading)), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.END,
        ).apply {
            marginEnd = dp(16)
            bottomMargin = dp(56)
        })
        loading = findViewById(R.id.loading)
        loadingOverlay = findViewById(R.id.loading_overlay)
        loadingBackdrop = findViewById(R.id.loading_backdrop)
        loadingTitle = findViewById(R.id.loading_title)
        loadingEpisode = findViewById(R.id.loading_episode)
        loadingStatus = findViewById(R.id.loading_status)
        loadingActions = findViewById(R.id.loading_actions)
        findViewById<View>(R.id.btn_loading_retry).setOnClickListener {
            switching = false
            loadEpisode(currentIndex)
        }
        findViewById<View>(R.id.btn_loading_back).setOnClickListener { finish() }
        loadingTitle.text = intent.getStringExtra(PhonePlayerIntent.EXTRA_TITLE) ?: ""
        loadingEpisode.text = intent.getStringExtra(PhonePlayerIntent.EXTRA_EP_LABEL) ?: ""
        loadingTitlePulse = findViewById(R.id.loading_title_pulse)
        val loadingLogoUrl = intent.getStringExtra("loadingLogo")
        loadingTitlePulse.startPulse()
        val artworkHeaders = PhonePlayerIntent.headersFromArray(
            intent.getStringArrayExtra("loadingArtworkHeaders"),
        ).orEmpty()
        loadingBackdrop.loadPlaybackArtwork(
            intent.getStringExtra("loadingArtwork"),
            artworkHeaders,
        )
        val logo = findViewById<android.widget.ImageView>(R.id.loading_logo)
        logo.loadPlaybackArtwork(loadingLogoUrl) {
            if (loadingOverlay.visibility != View.VISIBLE || loadingActions.visibility == View.VISIBLE) return@loadPlaybackArtwork
            logo.contentDescription = loadingTitle.text
            logo.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            logo.visibility = View.VISIBLE
            loadingTitle.visibility = View.GONE
        }
        controls = findViewById(R.id.controls)
        quickActions = findViewById(R.id.quick_actions)
        btnPlay = findViewById(R.id.btn_play)
        seek = findViewById(R.id.seek)
        timeText = findViewById(R.id.time_chip)
        titleText = findViewById(R.id.title)
        episodeText = findViewById(R.id.episode_label)
        isMovie = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_IS_MOVIE, false)

        titleText.text = intent.getStringExtra(PhonePlayerIntent.EXTRA_TITLE) ?: ""
        episodeText.text = if (isMovie) "" else (intent.getStringExtra(PhonePlayerIntent.EXTRA_EP_LABEL) ?: "")
        episodeText.visibility = if (isMovie) View.GONE else View.VISIBLE
        currentIndex = intent.getIntExtra(PhonePlayerIntent.EXTRA_START_INDEX, 0)
        loadedEpisodeIndex = currentIndex
        episodeCount = intent.getIntExtra(PhonePlayerIntent.EXTRA_EP_COUNT, 1)
        episodeLabels = intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_EP_LABELS) ?: emptyArray()
        autoplayNext = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_AUTOPLAY_NEXT, true)
        ambientEnabled = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_AMBIENT_ENABLED, true)
        seekMs = (intent.getIntExtra(PhonePlayerIntent.EXTRA_SEEK_SECONDS, 10) * 1000L)
            .coerceAtLeast(1_000L)
        subtitlePreference = intent.getStringExtra(PhonePlayerIntent.EXTRA_SUB_PREFERENCE).orEmpty()
        subtitleScale = intent.getFloatExtra(PhonePlayerIntent.EXTRA_SUB_SCALE, 1f)
        subtitlePosition = intent.getIntExtra(PhonePlayerIntent.EXTRA_SUB_POSITION, 95)
        subtitleBackground = intent.getIntExtra(
            PhonePlayerIntent.EXTRA_SUB_BG_COLOR, android.graphics.Color.TRANSPARENT,
        )
        subtitleForeground = intent.getIntExtra(PhonePlayerIntent.EXTRA_SUB_FG, android.graphics.Color.WHITE)
        subtitleEdgeType = intent.getIntExtra(PhonePlayerIntent.EXTRA_SUB_EDGE_TYPE, CaptionStyleCompat.EDGE_TYPE_OUTLINE)
        subtitleEdgeColor = intent.getIntExtra(PhonePlayerIntent.EXTRA_SUB_EDGE_COLOR, android.graphics.Color.BLACK)
        updateSubtitleFont(intent.getStringExtra(PhonePlayerIntent.EXTRA_SUB_FONT))

        bindWatchInfo()
        updateOrientationLayout()

        findViewById<View>(R.id.btn_back).setOnClickListener {
            if (!showWatchPage()) finish()
        }
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
        // The XML inflates the two-row actions; the portrait mini-card swaps
        // in its single-row variant before anything binds to it.
        if (isPortraitCard()) inflateQuickActions() else bindQuickActions()
        val cast = CastManager(this)
        castManager = cast
        castSupported = runCatching { cast.init() }.getOrDefault(false)
        if (!isPortraitCard()) applyFullscreenControls()
        updateEpisodeNavigation()

        seekPreview = PhoneSeekPreview(stage, seek)
        seek.setOnSeekBarChangeListener(object : android.widget.SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: android.widget.SeekBar, value: Int, fromUser: Boolean) {
                if (!fromUser) return
                val d = player?.duration ?: 0L
                if (d > 0) {
                    val pos = d * value / 1000
                    timeText.text = if (isPortraitCard()) fmt(pos).padStart(5, '0') + " / " + fmt(d).padStart(5, '0') else fmt(pos) + " / " + fmt(d)
                    sb.contentDescription = getString(R.string.phone_player_desc_seek) + ", " + fmt(pos) + " of " + fmt(d)
                    if (scrubbing) seekPreview.show(pos, fmt(pos))
                }
            }

            override fun onStartTrackingTouch(sb: android.widget.SeekBar) {
                scrubbing = true
                // Cancel the auto-hide: a slow scrub must not lose the bar.
                restoreControls()
                handler.removeCallbacks(hideRunnable)
                val duration = player?.duration ?: 0L
                if (duration > 0) {
                    val position = duration * sb.progress / 1000
                    seekPreview.show(position, fmt(position))
                }
            }

            override fun onStopTrackingTouch(sb: android.widget.SeekBar) {
                scrubbing = false
                seekPreview.hide()
                val d = player?.duration ?: 0L
                if (d > 0) player?.seekTo(d * sb.progress / 1000)
                bumpControls()
            }
        })

        val taps = android.view.GestureDetector(
            this,
            object : android.view.GestureDetector.SimpleOnGestureListener() {
                override fun onLongPress(e: MotionEvent) {
                    if (controlsLocked || gestureMode != 0 || pinchActive ||
                        !intent.getBooleanExtra(PhonePlayerIntent.EXTRA_HOLD_SPEED, true)
                    ) return
                    val p = player ?: return
                    if (!p.playWhenReady) return
                    val previous = p.playbackParameters
                    speedBeforeHold = previous
                    p.playbackParameters = PlaybackParameters(2f, previous.pitch)
                    holdSpeedBadge.visibility = View.VISIBLE
                }

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
            if (controlsLocked) {
                if (ev.actionMasked == MotionEvent.ACTION_UP) {
                    unlockControl?.visibility = if (unlockControl?.visibility == View.VISIBLE) View.GONE else View.VISIBLE
                }
            } else handlePlayerTouch(v, ev, taps)
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
                    maxHeapBytes = Runtime.getRuntime().maxMemory(),
                ),
            )
            .build()
        player = exo
        playerView.player = exo
        playerView.subtitleView?.apply {
            setApplyEmbeddedStyles(false)
            setApplyEmbeddedFontSizes(false)
        }
        applySubtitleStyle()
        exo.playbackParameters =
            PlaybackParameters(intent.getFloatExtra(PhonePlayerIntent.EXTRA_SPEED, 1f))

        exo.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() {
                playbackStarted = true
                sendDiscordPresence()
                PhonePlayerBridge.channel?.invokeMethod(
                    "playbackStarted",
                    mapOf("index" to currentIndex, "sessionId" to sessionId),
                )
                hideLoading()
            }

            // Force cues onto the user's vertical Position (0=top … 100=bottom).
            // Bottom padding alone can't do this: most VTT/SRT cues set their
            // own line and ignore it. Same helper the TV player uses.
            override fun onCues(cueGroup: androidx.media3.common.text.CueGroup) {
                renderSubtitleCues(cueGroup.cues)
            }

            override fun onPlaybackStateChanged(state: Int) {
                sendDiscordPresence()
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
                val pending = pendingAddonSubtitleId
                if (pending != null) {
                    for (group in tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }) {
                        for (index in 0 until group.length) {
                            if (group.getTrackFormat(index).id == pending) {
                                pendingAddonSubtitleId = null
                                selectTextTrack(TrackSelectionOverride(group.mediaTrackGroup, index))
                                return
                            }
                        }
                    }
                    return
                }
                applySubtitlePreference(tracks)
            }

            override fun onPlayerError(error: PlaybackException) {
                playbackError = true
                setBuffering(false)
                val forbidden = generateSequence<Throwable>(error) { it.cause }
                    .filterIsInstance<androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException>()
                    .any { it.responseCode == 403 }
                failover(forbidden)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                sendDiscordPresence()
                updateKeepScreenOn()
                syncPlayIcon()
                bumpControls()
                pip.setState(isPlaying, player?.videoSize?.width ?: 0, player?.videoSize?.height ?: 0)
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                pip.setState(player?.isPlaying == true, videoSize.width, videoSize.height)
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
        if (loadingActions.visibility == View.VISIBLE) loadingTitlePulse.startPulse()
        loadingActions.visibility = View.GONE
        loadingStatus.visibility = View.VISIBLE
        loadingEpisode.text = episodeLabel ?: episodeText.text
        setLoadingStatus(getString(R.string.phone_player_status_finding))
        setBuffering(false)
    }

    /** The center pause button is the same solid accent circle the indicator
     *  draws over; hide it while buffering or the morph reads as one blob. */
    private fun setBuffering(visible: Boolean) {
        val busy = visible || (isPortraitCard() && !playbackStarted && loadingActions.visibility != View.VISIBLE)
        loading.visibility =
            if (busy && loadingOverlay.visibility != View.VISIBLE) View.VISIBLE else View.GONE
        btnPlay.visibility = if (busy) View.INVISIBLE else View.VISIBLE
    }

    private fun hideLoading() {
        handler.removeCallbacks(resolveTimeout)
        handler.removeCallbacks(startTimeout)
        loadingOverlay.visibility = View.GONE
        loadingTitlePulse.stopPulse()
        setBuffering(false)
        everPlayed = true
    }

    private fun showLoadError(message: String) {
        handler.removeCallbacks(resolveTimeout)
        handler.removeCallbacks(startTimeout)
        loadingOverlay.visibility = View.VISIBLE
        loadingStatus.visibility = View.VISIBLE
        setLoadingStatus(message)
        loadingActions.visibility = View.VISIBLE
        loadingTitlePulse.stopPulse()
        setBuffering(false)
    }

    private fun updateEpisodeNavigation() {
        val prev = findViewById<View>(R.id.btn_previous)
        val next = findViewById<View>(R.id.btn_next)
        val hasPrev = currentIndex > 0
        val hasNext = currentIndex + 1 < episodeCount
        prev.visibility = if (hasPrev && !isMovie) View.VISIBLE else View.INVISIBLE
        next.visibility = if (hasNext && !isMovie) View.VISIBLE else View.INVISIBLE
        prev.isEnabled = hasPrev
        next.isEnabled = hasNext
        prev.alpha = if (hasPrev) 1f else 0.4f
        next.alpha = if (hasNext) 1f else 0.4f
        prev.isFocusable = hasPrev
        next.isFocusable = hasNext
        refreshWatchInfo()
    }

    private fun controlSpec(key: String): Triple<Int, Int, () -> Unit>? = when (key) {
        "speed" -> Triple(R.id.quick_speed, R.string.phone_player_title_speed, { showSpeedMenu() })
        "tracks" -> Triple(R.id.quick_tracks, R.string.phone_player_title_tracks, { showTracksMenu() })
        "quality" -> Triple(R.id.quick_quality, R.string.phone_player_title_quality, { showQualityMenu() })
        "sources" -> Triple(R.id.quick_sources, R.string.phone_player_title_sources, { showSourceMenu() })
        "more" -> Triple(R.id.quick_more, R.string.phone_player_title_more, { showMoreMenu() })
        "episodes" -> if (isMovie) null else
            Triple(R.id.quick_episodes, R.string.phone_player_title_episodes, { showEpisodeMenu() })
        "rotate" -> Triple(R.id.btn_rotate, R.string.phone_player_menu_rotate, { toggleRotation() })
        "fit" -> Triple(R.id.quick_display, R.string.phone_player_menu_display, { cycleDisplayMode() })
        "cast" -> if (castSupported) Triple(R.id.quick_cast, R.string.phone_player_menu_cast, { pickCast() }) else null
        "info" -> Triple(R.id.quick_info, R.string.phone_player_title_playback_info, { showInfo() })
        "lock" -> Triple(R.id.btn_controls_lock, R.string.phone_player_lock_controls, { setControlsLocked(true) })
        "settings" -> Triple(R.id.btn_controls_settings, R.string.phone_player_arrange_controls, { showControlArrangement() })
        else -> null
    }

    private val fullscreenIcons = mutableMapOf<String, android.graphics.drawable.Drawable>()

    private fun fullscreenIcon(key: String): android.graphics.drawable.Drawable? {
        fullscreenIcons[key]?.let { return it }
        val font = controlIconFont ?: return null
        val glyph = PhonePlayerControlLayout.iconCodePoints[key] ?: return null
        val size = dp(when (key) { "play", "pause" -> 34; "previous", "next" -> 26; else -> 24 })
        val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.density = resources.displayMetrics.densityDpi
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            typeface = font
            textSize = size.toFloat()
            color = android.graphics.Color.WHITE
            textAlign = android.graphics.Paint.Align.CENTER
        }
        android.graphics.Canvas(bitmap).drawText(String(Character.toChars(glyph)), size / 2f,
            size / 2f - (paint.ascent() + paint.descent()) / 2f, paint)
        return android.graphics.drawable.BitmapDrawable(resources, bitmap).also { fullscreenIcons[key] = it }
    }

    private fun controlButton(key: String): View? {
        val (viewId, label, action) = controlSpec(key) ?: return null
        val fallback = when (key) {
            "speed" -> R.drawable.phone_player_speed
            "tracks" -> R.drawable.phone_player_tracks
            "quality" -> R.drawable.phone_player_quality
            "sources" -> R.drawable.phone_player_sources
            "more" -> R.drawable.phone_player_more
            "episodes" -> R.drawable.phone_player_episodes
            "rotate" -> R.drawable.phone_player_rotate
            "fit" -> R.drawable.phone_player_display
            "cast" -> R.drawable.phone_player_cast
            "info" -> R.drawable.phone_player_info
            "lock" -> android.R.drawable.ic_lock_lock
            else -> android.R.drawable.ic_menu_preferences
        }
        return android.widget.ImageButton(this).apply {
            id = viewId
            setImageDrawable(fullscreenIcon(key) ?: getDrawable(fallback))
            setPadding(dp(12), dp(12), dp(12), dp(12))
            scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
            imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.WHITE)
            contentDescription = getString(label)
            if (android.os.Build.VERSION.SDK_INT >= 26) tooltipText = getString(label)
            isClickable = true
            isFocusable = true
            background = android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(0x33FFFFFF), null,
                android.graphics.drawable.GradientDrawable().apply {
                    shape = android.graphics.drawable.GradientDrawable.OVAL
                    setColor(android.graphics.Color.WHITE)
                },
            )
            setOnClickListener { bumpControls(); action() }
        }
    }

    private fun applyFullscreenControls() {
        if (isPortraitCard()) return
        val topBar = controls.findViewById<LinearLayout>(R.id.top_bar)
        var top = topBar.findViewById<LinearLayout>(R.id.fullscreen_top_actions)
        if (top == null) {
            top = LinearLayout(this).apply {
                id = R.id.fullscreen_top_actions
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            topBar.addView(top, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(48)))
        }
        top.visibility = View.VISIBLE
        controls.findViewById<View>(R.id.btn_more)?.visibility = View.GONE
        fun fill(group: LinearLayout, keys: List<String>) {
            group.removeAllViews()
            for (key in keys) controlButton(key)?.let {
                group.addView(it, LinearLayout.LayoutParams(dp(48), dp(48)))
            }
            group.visibility = if (group.childCount == 0) View.GONE else View.VISIBLE
        }
        fill(top, controlLayout.top + listOf("lock", "settings"))
        val left = quickActions.findViewById<LinearLayout>(R.id.fullscreen_actions_left) ?: return
        val right = quickActions.findViewById<LinearLayout>(R.id.fullscreen_actions_right) ?: return
        fill(left, controlLayout.left)
        fill(right, controlLayout.right)
        // The same 48dp controls scroll on narrow windows instead of shrinking hit targets.
        (left.parent as View).minimumWidth = dp((left.childCount + right.childCount) * 48 + 16)
    }

    private fun showControlArrangement() {
        handler.removeCallbacks(hideRunnable)
        val keys = listOf("speed", "tracks", "quality", "sources", "more", "episodes", "rotate", "fit", "cast", "info")
            .filter { it != "episodes" || !isMovie }
        val labels = keys.map { key ->
            val label = when (key) {
                "cast" -> getString(R.string.phone_player_menu_cast)
                else -> getString(controlSpec(key)!!.second)
            }
            val slot = controlLayout.asMap().entries.firstOrNull { key in it.value }?.key ?: "hidden"
            "$label · ${controlSlotLabel(slot)}"
        }.toTypedArray()
        PhonePlayerSheet(this)
            .setTitle(R.string.phone_player_arrange_controls)
            .setItems(labels) { _, index ->
                val key = keys[index]
                val slots = listOf("top", "left", "right", "hidden")
                val current = controlLayout.asMap().entries.firstOrNull { key in it.value }?.key ?: "hidden"
                PhonePlayerSheet(this)
                    .setTitle(labels[index].substringBefore(" · "))
                    .setSingleChoiceItems(slots.map { controlSlotLabel(it) }.toTypedArray(), slots.indexOf(current)) { dialog, choice ->
                        dialog.dismiss()
                        val next = controlLayout.move(key, slots[choice])
                        if (next == null) {
                            toast(getString(R.string.phone_player_controls_limit))
                            return@setSingleChoiceItems
                        }
                        val channel = PhonePlayerBridge.channel
                        if (channel == null) {
                            toast(getString(R.string.phone_player_controls_save_error))
                            return@setSingleChoiceItems
                        }
                        channel.invokeMethod("saveControlLayout", next.asMap() + ("sessionId" to sessionId), object : io.flutter.plugin.common.MethodChannel.Result {
                            override fun success(result: Any?) {
                                if (!uiAlive()) return
                                if (result == true) {
                                    controlLayout = next
                                    applyFullscreenControls()
                                    bumpControls()
                                } else toast(getString(R.string.phone_player_controls_save_error))
                            }
                            override fun error(code: String, message: String?, details: Any?) {
                                if (uiAlive()) toast(getString(R.string.phone_player_controls_save_error))
                            }
                            override fun notImplemented() {
                                if (uiAlive()) toast(getString(R.string.phone_player_controls_save_error))
                            }
                        })
                    }.setOnDismissListener { bumpControls() }.show()
            }.setOnDismissListener { bumpControls() }.show()
    }

    private fun controlSlotLabel(slot: String) = getString(when (slot) {
        "top" -> R.string.phone_player_controls_top
        "left" -> R.string.phone_player_controls_left
        "right" -> R.string.phone_player_controls_right
        else -> R.string.phone_player_controls_hidden
    })

    private fun setControlsLocked(locked: Boolean) {
        if (locked) {
            restoreSpeedAfterHold()
            updateSegmentButton(null)
        }
        controlsLocked = locked
        if (unlockControl == null) {
            val column = LinearLayout(this).apply {
                id = R.id.btn_controls_unlock
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                isClickable = true
                isFocusable = true
                contentDescription = getString(R.string.phone_player_unlock_controls)
                setOnClickListener { setControlsLocked(false) }
            }
            column.addView(TextView(this).apply {
                text = String(Character.toChars(PhonePlayerControlLayout.iconCodePoints.getValue("unlock")))
                typeface = controlIconFont
                textSize = 24f
                setTextColor(android.graphics.Color.WHITE)
                gravity = Gravity.CENTER
                background = getDrawable(R.drawable.phone_player_transport_disc)
            }, LinearLayout.LayoutParams(dp(48), dp(48)))
            column.addView(TextView(this).apply {
                text = getString(R.string.phone_player_unlock_controls)
                textSize = 13f
                setTextColor(android.graphics.Color.WHITE)
                setPadding(0, dp(8), 0, 0)
            })
            (findViewById<View>(R.id.player_root) as ViewGroup).addView(column,
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
            unlockControl = column
        }
        unlockControl?.visibility = if (locked) View.VISIBLE else View.GONE
        if (locked) {
            handler.removeCallbacks(hideRunnable)
            controls.animate().cancel()
            controlsHiding = false
            controls.visibility = View.GONE
        } else { restoreControls(); bumpControls() }
    }

    private fun bindQuickActions() {
        if (quickActions.findViewById<View>(R.id.fullscreen_actions_left) != null) {
            applyFullscreenControls()
            return
        }
        quickActions.findViewById<View>(R.id.btn_rotate).setOnClickListener { toggleRotation() }
        quickActions.findViewById<View>(R.id.quick_episodes)?.apply {
            visibility = if (isMovie) View.GONE else View.VISIBLE
            setOnClickListener { showEpisodeMenu() }
        }
        quickActions.findViewById<View>(R.id.quick_sources).setOnClickListener { showSourceMenu() }
        quickActions.findViewById<View>(R.id.quick_tracks).setOnClickListener { showTracksMenu() }
        quickActions.findViewById<View>(R.id.quick_quality).setOnClickListener { showQualityMenu() }
        quickActions.findViewById<View>(R.id.quick_speed).setOnClickListener { showSpeedMenu() }
        quickActions.findViewById<View>(R.id.quick_display).setOnClickListener { showDisplayMenu() }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        restoreSpeedAfterHold()
        resetRotationPull(animate = false)
        super.onConfigurationChanged(newConfig)
        moreDialog?.dismiss()
        episodePanel?.dismiss()
        watchPage = newConfig.orientation == Configuration.ORIENTATION_PORTRAIT
        updateOrientationLayout()
        inflateQuickActions()
    }

    /** dp→px for the appearance-only layout tweaks below. */
    private fun dp(value: Int) =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    /** Mini-card layout: the portrait watch page fits top bar + transport +
     * single action row + time + seek with no overlap (the card is only as
     * tall as the 16:9 stage). Landscape keeps the full-size chrome. */
    private fun isPortraitCard() =
        watchPage && resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT

    private fun quickActionsLayoutRes() =
        if (isPortraitCard()) R.layout.phone_player_quick_actions_portrait
        else R.layout.phone_player_quick_actions

    private fun inflateQuickActions() {
        val parent = quickActions.parent as ViewGroup
        val index = parent.indexOfChild(quickActions)
        parent.removeViewAt(index)
        quickActions = layoutInflater.inflate(quickActionsLayoutRes(), parent, false) as ViewGroup
        parent.addView(quickActions, index)
        bindQuickActions()
        quickActions.visibility = if (isPortraitCard()) View.GONE else View.VISIBLE
    }

    private fun updateFullscreenTimeRow(mini: Boolean) {
        val row = timeText.parent as LinearLayout
        row.gravity = Gravity.START or Gravity.CENTER_VERTICAL
        var skip = row.findViewById<View>(R.id.quick_mega_skip)
        if (skip == null && !mini && megaSkipEnabled) {
            row.addView(android.widget.Space(this).apply { id = R.id.fullscreen_time_spacer },
                LinearLayout.LayoutParams(0, 1, 1f))
            val pill = LinearLayout(this).apply {
                id = R.id.quick_mega_skip
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(dp(10), 0, dp(12), 0)
                background = android.graphics.drawable.GradientDrawable().apply {
                    setColor(0x4D000000)
                    cornerRadius = dp(13).toFloat()
                }
                isClickable = true
                isFocusable = true
                contentDescription = getString(R.string.phone_player_mega_skip_description, megaSkipSeconds)
                setOnClickListener {
                    val active = player ?: return@setOnClickListener
                    val target = megaSkipTarget(active.currentPosition, active.duration, megaSkipSeconds)
                        ?: return@setOnClickListener
                    active.seekTo(target)
                    bumpControls()
                }
            }
            pill.addView(android.widget.ImageView(this).apply {
                setImageDrawable(fullscreenIcon("megaSkip") ?: getDrawable(R.drawable.phone_player_next))
                imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.WHITE)
            }, LinearLayout.LayoutParams(dp(18), dp(18)))
            pill.addView(TextView(this).apply {
                text = getString(R.string.phone_player_mega_skip_label, megaSkipSeconds)
                textSize = 13.5f
                typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
                includeFontPadding = false
                setTextColor(android.graphics.Color.WHITE)
                setPadding(dp(5), 0, 0, 0)
            })
            row.addView(pill, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(28)))
            skip = pill
        }
        val visibility = if (!mini && megaSkipEnabled) View.VISIBLE else View.GONE
        skip?.visibility = visibility
        row.findViewById<View>(R.id.fullscreen_time_spacer)?.visibility = visibility
    }

    private fun updateOrientationLayout() {
        goImmersive()
        val portrait =
            resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
        val video = findViewById<View>(R.id.player_root)
        val root = findViewById<View>(R.id.watch_root)
        if (portrait && watchPage) {
            // Reattach the glow if a previous layout pass flattened it to black;
            // a fresh page starts unfaded. Off (ambientEnabled == false) stays
            // plain black and never (re)starts sampling.
            val ambient = if (ambientEnabled) ambientLayer else null
            if (ambient != null) {
                ambientDrawable?.alpha = 255
                ambientInfoDrawable?.alpha = 255
                root.background = ambient
            } else {
                root.setBackgroundColor(android.graphics.Color.BLACK)
                // applyAmbientColors only ever SETS this background from the
                // sampling loop — stopping that loop leaves whatever glow it
                // last painted here, so clear it explicitly.
                watchPanel?.header?.background = null
            }
            val edgeToEdge = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_PORTRAIT_VIDEO_EDGE_TO_EDGE, false)
            val w = resources.displayMetrics.widthPixels
            val m = if (edgeToEdge) 0 else dp(12)
            video.layoutParams = video.layoutParams.apply {
                height = minOf((w - 2 * m) * 9 / 16, (resources.displayMetrics.heightPixels * .38f).toInt()).coerceAtLeast(1)
                if (this is android.widget.LinearLayout.LayoutParams) {
                    setMargins(m, dp(4), m, 0)
                }
            }
            if (edgeToEdge) video.setBackgroundColor(android.graphics.Color.BLACK)
            else video.background = getDrawable(R.drawable.phone_player_video_card)
            video.clipToOutline = !edgeToEdge
            val info = ensureWatchInfo()
            info?.visibility = View.VISIBLE
            if (ambientEnabled) startAmbient()
        } else {
            root.setBackgroundColor(getColor(R.color.phone_player_background))
            val lp = video.layoutParams
            lp.height = ViewGroup.LayoutParams.MATCH_PARENT
            if (lp is android.widget.LinearLayout.LayoutParams) {
                lp.setMargins(0, 0, 0, 0)
            }
            video.layoutParams = lp
            video.background = null
            video.clipToOutline = false
            watchInfo?.visibility = View.GONE
            stopAmbient()
        }
        val topScrim = controls.findViewById<View>(R.id.top_scrim)
        topScrim.setBackgroundResource(if (portrait && watchPage)
            R.drawable.phone_player_scrim_top else R.drawable.phone_player_fullscreen_scrim_top)
        topScrim.layoutParams = topScrim.layoutParams.apply {
            height = resources.getDimensionPixelSize(
                if (portrait && watchPage) R.dimen.phone_player_top_scrim_height_portrait
                else R.dimen.phone_player_top_scrim_height,
            )
        }
        val bottomScrim = controls.findViewById<View>(R.id.bottom_scrim)
        bottomScrim.setBackgroundResource(if (portrait && watchPage)
            R.drawable.phone_player_scrim_bottom else R.drawable.phone_player_fullscreen_scrim_bottom)
        bottomScrim.layoutParams = bottomScrim.layoutParams.apply {
            height = resources.getDimensionPixelSize(
                if (portrait && watchPage) R.dimen.phone_player_bottom_scrim_height_portrait
                else R.dimen.phone_player_bottom_scrim_height,
            )
        }
        val topBar = controls.findViewById<View>(R.id.top_bar)
        val topBarParams = topBar.layoutParams as android.widget.FrameLayout.LayoutParams
        val mini = portrait && watchPage
        updateFullscreenTimeRow(mini)
        for ((id, key, fallback) in listOf(
            Triple(R.id.btn_back, "back", R.drawable.phone_player_back),
            Triple(R.id.btn_previous, "previous", R.drawable.phone_player_previous),
            Triple(R.id.btn_next, "next", R.drawable.phone_player_next),
        )) {
            controls.findViewById<android.widget.ImageView>(id).setImageDrawable(
                fullscreenIcon(if (mini && key == "back") "miniBack" else key) ?: getDrawable(fallback))
        }
        // Portrait card insets the stage, so the bar hugs the card edge like
        // the MPV mini-player back (landscape keeps the fullscreen margins).
        // The title, episode and ⋮ live again inches below in the info panel,
        // so the mini card keeps only Back — otherwise top bar + transport +
        // actions + seek cannot fit the 16:9 stage without overlapping.
        val topSide = if (mini) dp(6) else
            resources.getDimensionPixelSize(R.dimen.phone_player_top_bar_side_margin)
        topBarParams.marginStart = topSide
        topBarParams.marginEnd = topSide
        topBarParams.topMargin = if (mini) dp(6) else
            resources.getDimensionPixelSize(R.dimen.phone_player_top_bar_top_margin)
        topBarParams.bottomMargin = if (mini) 0 else dp(8)
        topBar.layoutParams = topBarParams
        val topPadding = 0
        topBar.setPadding(topPadding, topPadding, topPadding, topPadding)
        controls.findViewById<View>(R.id.title)?.visibility =
            if (mini) View.GONE else View.VISIBLE
        controls.findViewById<View>(R.id.episode_label)?.visibility =
            if (mini || isMovie) View.GONE else View.VISIBLE
        controls.findViewById<View>(R.id.fullscreen_top_actions)?.visibility =
            if (mini) View.GONE else View.VISIBLE
        controls.findViewById<View>(R.id.btn_more)?.visibility =
            if (mini) View.GONE else View.VISIBLE
        // Mini-player back glyph reads smaller (18dp); fullscreen keeps 24dp.
        val backPad = dp(if (mini) 7 else 12)
        controls.findViewById<View>(R.id.btn_back).apply {
            layoutParams = layoutParams.apply { width = dp(if (mini) 32 else 48); height = width }
            background = if (mini) android.graphics.drawable.GradientDrawable().apply {
                shape = android.graphics.drawable.GradientDrawable.OVAL; setColor(0x80000000.toInt())
            } else getDrawable(R.drawable.phone_player_icon_ripple)
        }
        controls.findViewById<android.widget.ImageView>(R.id.btn_back)?.setPadding(backPad, backPad, backPad, backPad)
        // The mini card stacks bar → transport → actions → time → seek with no
        // overlap; fullscreen centers the transport over the picture.
        val transport = controls.findViewById<View>(R.id.transport_row)
        val transportParams = transport.layoutParams as android.widget.FrameLayout.LayoutParams
        transportParams.gravity = if (mini)
            android.view.Gravity.TOP or android.view.Gravity.CENTER_HORIZONTAL
        else android.view.Gravity.CENTER
        transportParams.topMargin = if (mini) ((video.layoutParams.height - dp(116)) * .75f).toInt().coerceAtLeast(0) else 0
        for (id in listOf(R.id.btn_previous, R.id.btn_next)) {
            controls.findViewById<View>(id).apply {
                layoutParams = (layoutParams as android.widget.LinearLayout.LayoutParams).apply {
                    width = dp(if (mini) 44 else 46); height = width
                    if (id == R.id.btn_previous) marginEnd = dp(if (mini) 16 else 24)
                    else marginStart = dp(if (mini) 16 else 24)
                }
            }
        }
        val loadingParams = loading.layoutParams as android.widget.FrameLayout.LayoutParams
        loadingParams.gravity = if (mini) Gravity.TOP or Gravity.CENTER_HORIZONTAL else Gravity.CENTER
        loadingParams.topMargin = if (mini) transportParams.topMargin else 0
        loading.layoutParams = loadingParams
        transport.layoutParams = transportParams
        // Slightly smaller play disc in the mini card so the stack fits.
        val playBox = btnPlay.parent as View
        val playBoxParams = playBox.layoutParams
        playBoxParams.width = dp(if (mini) 56 else 58)
        playBoxParams.height = dp(if (mini) 56 else 58)
        playBox.layoutParams = playBoxParams
        val playPad = dp(12)
        btnPlay.setPadding(playPad, playPad, playPad, playPad)
        // Match the compact fullscreen seek row without changing the mini card.
        val bottomBar = controls.findViewById<View>(R.id.bottom_bar)
        bottomBar.setPadding(dp(4), 0, dp(4), 0)
        val seekBar = controls.findViewById<View>(R.id.seek)
        val seekParams = seekBar.layoutParams
        seekParams.height = dp(if (mini) 24 else 26)
        seekBar.layoutParams = seekParams
        seek.thumb = getDrawable(if (mini) R.drawable.phone_watch_seek_thumb else R.drawable.phone_player_seek_thumb)
        seek.progressDrawable = getDrawable(if (mini) R.drawable.phone_watch_seek_track else R.drawable.phone_player_seek_track)
        val radius = seek.thumb.intrinsicWidth / 2
        seek.setPadding(radius, dp(if (mini) 7 else 6), radius, dp(if (mini) 7 else 6))
        seek.thumbOffset = radius
        val accent = ColorStateList.valueOf(
            intent.getIntExtra(PhonePlayerIntent.EXTRA_ACCENT, getColor(R.color.phone_player_accent)),
        )
        seek.thumbTintList = accent
        seek.progressTintList = accent
        val timeRow = timeText.parent as ViewGroup
        val bar = bottomBar as ViewGroup
        bar.removeView(timeRow)
        bar.addView(timeRow, if (mini) 1 else 0)
        timeRow.setPadding(0, 0, 0, 0)
        timeText.apply {
            textSize = if (mini) 13f else 12.5f
            typeface = android.graphics.Typeface.create(if (mini) "sans-serif" else "sans-serif-medium", if (mini) android.graphics.Typeface.NORMAL else android.graphics.Typeface.BOLD)
            background = if (mini) null else getDrawable(R.drawable.phone_player_time_chip)
            setPadding(dp(if (mini) 0 else 8), dp(if (mini) 0 else 2), dp(if (mini) 0 else 8), dp(if (mini) 0 else 2))
        }
        quickActions.visibility = if (mini) View.GONE else View.VISIBLE
        var expand = timeRow.findViewById<View>(R.id.watch_expand)
        if (expand == null && mini) {
            expand = android.widget.ImageButton(this).apply {
                id = R.id.watch_expand
                setImageDrawable(fullscreenIcon("fullscreen"))
                background = null
                setPadding(dp(4), dp(4), dp(4), dp(4))
                contentDescription = getString(R.string.phone_player_watch_fullscreen)
                setOnClickListener { toggleRotation() }
            }
            timeRow.addView(expand, LinearLayout.LayoutParams(dp(32), dp(32)))
        }
        expand?.visibility = if (mini) View.VISIBLE else View.GONE
        var miniSpace = timeRow.findViewWithTag<View>("mini_time_spacer")
        if (miniSpace == null && mini) {
            miniSpace = android.widget.Space(this).apply { tag = "mini_time_spacer" }
            timeRow.addView(miniSpace, timeRow.indexOfChild(expand), LinearLayout.LayoutParams(0, 1, 1f))
        }
        miniSpace?.visibility = if (mini) View.VISIBLE else View.GONE
        val bottomBarParams = bottomBar.layoutParams as android.widget.FrameLayout.LayoutParams
        bottomBarParams.marginStart = dp(if (mini) 12 else 40)
        bottomBarParams.marginEnd = dp(if (mini) 12 else 40)
        bottomBarParams.bottomMargin = if (mini) dp(4) else
            resources.getDimensionPixelSize(R.dimen.phone_player_bottom_bar_bottom_margin)
        bottomBar.layoutParams = bottomBarParams
        if (mini) {
            timeText.setTextColor(android.graphics.Color.WHITE)
            timeText.text = fmt(player?.currentPosition ?: 0L).padStart(5, '0') + " / " + fmt((player?.duration ?: 0L).coerceAtLeast(0L)).padStart(5, '0')
        }
    }

    /** Late enrichment from Dart; session-checked in [PhonePlayerBridge]. */
    fun onMetadataUpdate(description: String?) {
        pendingDesc = description
        applyPendingDesc()
    }

    private fun applyPendingDesc() {
        val info = watchPanel?.header ?: return
        val desc = watchPanel?.row(currentIndex)?.description?.ifBlank { null } ?: pendingDesc?.trim().orEmpty()
        info.findViewById<TextView>(R.id.watch_description)?.apply {
            visibility = if (desc.isEmpty()) View.GONE else View.VISIBLE
            PhoneWatchMotion.text(this, desc)
        }
        info.findViewById<TextView>(R.id.watch_see_more)?.apply {
            visibility = if (desc.isEmpty()) View.GONE else View.VISIBLE
            text = getString(R.string.phone_player_watch_see_more)
        }
        info.findViewById<View>(R.id.watch_description_card).visibility = if (desc.isEmpty()) View.GONE else View.VISIBLE
        descExpanded = false
    }

    private fun bindWatchInfo() {
        // Panel content refreshes from player state; this only wires static
        // structure once the stub exists (see updateOrientationLayout).
        refreshWatchInfo()
    }

    private var ambientHandler: android.os.Handler? = null
    private var ambientDrawable: android.graphics.drawable.GradientDrawable? = null
    private var ambientLayer: android.graphics.drawable.LayerDrawable? = null
    private var ambientInfoDrawable: android.graphics.drawable.GradientDrawable? = null
    private var ambientAnimator: android.animation.ValueAnimator? = null
    private var ambientTopColor = android.graphics.Color.BLACK
    private var ambientBottomColor = android.graphics.Color.BLACK
    private var ambientReady = false
    private val ambientRunnable = object : Runnable {
        override fun run() {
            if (!uiAlive() || watchInfo == null) return
            // A paused picture never changes — resampling it only burns
            // battery for identical colors (mpv's sampler does the same).
            if (player?.isPlaying != true && ambientReady) {
                ambientHandler?.postDelayed(this, 6_000L)
                return
            }
            // A tiny grab is enough to average a color from — no need for a
            // full-resolution frame just to collapse it to one swatch. The
            // crop drops letterbox bars so the average is the picture, not
            // the black around it (mpv screenshots the frame, not the view).
            val view = textureView()
            val vw = view?.width ?: 0
            val vh = view?.height ?: 0
            val frame = if (view != null && vw > 0 && vh > 0) {
                runCatching { view.getBitmap(32, (32 * vh / vw).coerceAtLeast(1)) }.getOrNull()
            } else null
            if (frame != null) {
                // Letterbox bars only exist in FIT mode — in FILL/ZOOM the
                // video already covers the view, so cropping as if there
                // were bars would sample the wrong sub-rect.
                val vs = if (playerView.resizeMode == AspectRatioFrameLayout.RESIZE_MODE_FIT) {
                    player?.videoSize
                } else null
                val r = videoSampleRect(frame.width, frame.height, vs?.width ?: 0, vs?.height ?: 0)
                val cropped = if (r[0] != 0 || r[1] != 0 || r[2] != frame.width || r[3] != frame.height) {
                    runCatching { android.graphics.Bitmap.createBitmap(frame, r[0], r[1], r[2], r[3]) }.getOrNull()
                } else null
                val (top, bottom) = ambientGlowColor(cropped ?: frame)
                cropped?.recycle()
                frame.recycle()
                val lum = (((top shr 16) and 0xFF) + ((top shr 8) and 0xFF) + (top and 0xFF) +
                    ((bottom shr 16) and 0xFF) + ((bottom shr 8) and 0xFF) + (bottom and 0xFF)) / 6
                // A fully unreadable grab must not paint an existing glow away.
                if (lum >= 28 || !ambientReady) applyAmbientColors(top, bottom)
            }
            ambientHandler?.postDelayed(this, 6_000L)
        }
    }

    /**
     * mpv's two pieces: a radial glow bounded to just the top strip
     * (status bar through the end of the video card), plus a linear
     * wash on the header row below it. The strip is hard-bounded via a
     * LayerDrawable inset over a black base, same as mpv's own Positioned
     * box — nothing paints past it, so a corner like the card's rounded
     * bottom never picks up a residual tint (a GradientDrawable paints its
     * edge color flat everywhere past its radius; unbounded, that leaked
     * into the card's corners and made their curve visible). The hot
     * center sits inside the video card so the brightest ring is hidden
     * behind the opaque video, and the header's starting alpha is
     * computed to exactly continue the radial's tail at the boundary.
     * Colors crossfade over 900ms, same pace as mpv's AnimatedSwitcher.
     */
    private fun applyAmbientColors(newTop: Int, newBottom: Int) {
        val root = findViewById<View>(R.id.watch_root)
        val card = findViewById<View>(R.id.player_root)
        if (root.height <= 0 || card.height <= 0) return
        val stripHeight = (card.bottom + dp(4)).coerceAtMost(root.height)
        val radius = 1.4f * minOf(root.width, stripHeight).toFloat()
        val centerYPx = card.top + card.height * 0.8f
        val drawable = ambientDrawable ?: android.graphics.drawable.GradientDrawable().also {
            it.gradientType = android.graphics.drawable.GradientDrawable.RADIAL_GRADIENT
            ambientDrawable = it
        }
        val layer = ambientLayer ?: android.graphics.drawable.LayerDrawable(arrayOf(
            android.graphics.drawable.ColorDrawable(android.graphics.Color.BLACK), drawable,
        )).also { ambientLayer = it }
        layer.setLayerInset(1, 0, 0, 0, (root.height - stripHeight).coerceAtLeast(0))
        // updateOrientationLayout may have replaced the background with a
        // flat color; reattach so the glow survives rotation.
        root.background = layer
        // The inset shrinks the radial's own bounds to the strip, so its
        // center fraction has to be measured against stripHeight, not
        // root.height — otherwise it lands in the wrong place.
        drawable.setGradientCenter(0.5f, (centerYPx / stripHeight).coerceIn(0f, 1f))
        drawable.gradientRadius = radius
        // GradientDrawable interpolates linearly from the center color to
        // the edge color over [0, radius] — same math here, so this is
        // exactly what the radial itself renders at the boundary, not a
        // guess.
        val edgeFraction = ((stripHeight - centerYPx).coerceAtLeast(0f) / radius).coerceIn(0f, 1f)
        val headerStartAlpha = (166 + (64 - 166) * edgeFraction + 0.5f).toInt().coerceIn(0, 255)
        val info = ambientInfoDrawable ?: android.graphics.drawable.GradientDrawable(
            android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
            intArrayOf(0, 0, 0),
        ).also { ambientInfoDrawable = it }
        watchPanel?.header?.background = info
        val fromTop = ambientTopColor
        val fromBottom = ambientBottomColor
        val evaluator = android.animation.ArgbEvaluator()
        ambientAnimator?.cancel()
        ambientAnimator = android.animation.ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 900L
            addUpdateListener { anim ->
                val f = anim.animatedValue as Float
                val t = evaluator.evaluate(f, fromTop, newTop) as Int
                val b = evaluator.evaluate(f, fromBottom, newBottom) as Int
                drawable.setColors(intArrayOf(withAlpha(b, 166), withAlpha(t, 64)))
                info.setColors(intArrayOf(
                    withAlpha(b, headerStartAlpha),
                    withAlpha(b, headerStartAlpha / 2),
                    withAlpha(b, 0),
                ))
                // Track what's actually on screen, not the target — a tick
                // landing mid-crossfade must resume from here, not snap.
                ambientTopColor = t
                ambientBottomColor = b
            }
            start()
        }
        ambientReady = true
    }

    /** Fades the glow out over the same 180dp of scroll mpv's watch page
     * uses, so it reads as a smooth dissolve into the list instead of an
     * episode row abruptly scrolling over a still-fully-lit background. */
    private fun installAmbientScrollFade(rv: androidx.recyclerview.widget.RecyclerView) {
        val fadeDistance = dp(180)
        rv.addOnScrollListener(object : androidx.recyclerview.widget.RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: androidx.recyclerview.widget.RecyclerView, dx: Int, dy: Int) {
                val offset = recyclerView.computeVerticalScrollOffset()
                val fraction = (1f - offset.toFloat() / fadeDistance).coerceIn(0f, 1f)
                ambientDrawable?.alpha = (fraction * 255).toInt()
                ambientInfoDrawable?.alpha = (fraction * 255).toInt()
            }
        })
    }

    private fun startAmbient() {
        if (ambientHandler != null) return
        ambientHandler = handler
        handler.post(ambientRunnable)
    }

    private fun stopAmbient() {
        ambientHandler?.removeCallbacks(ambientRunnable)
        ambientHandler = null
        ambientAnimator?.cancel()
        ambientAnimator = null
    }

    private fun ensureWatchInfo(): ViewGroup? {
        watchInfo?.let { return it }
        val stub = findViewById<ViewStub>(R.id.watch_info_stub) ?: return null
        val inflated = stub.inflate() as? androidx.recyclerview.widget.RecyclerView ?: return null
        watchInfo = inflated
        installAmbientScrollFade(inflated)
        val panel = PhoneWatchPage(inflated, PhonePlayerBridge.watchDataFor(sessionId), episodeLabels,
            intent.getIntExtra(PhonePlayerIntent.EXTRA_ACCENT, getColor(R.color.phone_player_accent)),
            { fullscreenIcon(it)?.constantState?.newDrawable(resources)?.mutate() }) { index ->
                bumpControls()
                if (index != currentIndex) loadEpisode(index)
            }
        watchPanel = panel
        panel.onEpisodeMenu = { showWatchEpisodeMenu(it) }
        panel.onEpisodeDownload = { showWatchDownload(it) }
        val header = panel.header
        header.findViewById<View>(R.id.watch_action_server)?.setOnClickListener {
            bumpControls(); showSourceMenu()
        }
        header.findViewById<View>(R.id.watch_action_audio)?.setOnClickListener {
            bumpControls(); showTracksMenu()
        }
        header.findViewById<View>(R.id.watch_action_subtitles)?.setOnClickListener {
            bumpControls(); showTracksMenu()
        }
        header.findViewById<View>(R.id.watch_action_more)?.setOnClickListener {
            bumpControls(); showMoreMenu()
        }
        header.findViewById<View>(R.id.watch_comments)?.setOnClickListener {
            showComingSoon()
        }
        val desc = header.findViewById<TextView>(R.id.watch_description)
        val seeMore = header.findViewById<TextView>(R.id.watch_see_more)
        val toggle: () -> Unit = {
            PhoneWatchMotion.resize(header.findViewById<ViewGroup>(R.id.watch_description_card)) {
            descExpanded = !descExpanded
            desc?.maxLines = if (descExpanded) Int.MAX_VALUE else 3
            seeMore?.text = getString(
                if (descExpanded) R.string.phone_player_watch_see_less
                else R.string.phone_player_watch_see_more,
            )
            }
        }
        desc?.setOnClickListener { toggle() }
        seeMore?.setOnClickListener { toggle() }
        header.findViewById<CheckBox>(R.id.watch_autoplay)?.apply {
            isChecked = autoplayNext
            setOnCheckedChangeListener { _, checked ->
                autoplayNext = checked
                PhonePlayerBridge.channel?.invokeMethod(
                    "setAutoplayNext",
                    mapOf("value" to checked),
                )
                bumpControls()
            }
        }
        applyPendingDesc()
        refreshWatchInfo()
        return inflated
    }

    private fun refreshWatchInfo() {
        val panel = watchPanel ?: return
        val row = panel.row(currentIndex)
        PhoneWatchMotion.text(panel.header.findViewById(R.id.watch_title), row?.title?.ifBlank { null } ?: titleText.text)
        PhoneWatchMotion.text(panel.header.findViewById(R.id.watch_episode_label), row?.subtitle?.ifBlank { null } ?: episodeText.text)
        val description = row?.description?.ifBlank { null } ?: pendingDesc.orEmpty()
        panel.header.findViewById<View>(R.id.watch_description_card).visibility = if (description.isEmpty()) View.GONE else View.VISIBLE
        PhoneWatchMotion.text(panel.header.findViewById(R.id.watch_description), description)
        panel.update(currentIndex)
    }

    private var watchDownloadSheet: PhoneWatchDownloadSheet? = null

    private fun showWatchDownload(index: Int) {
        if (!isPortraitCard() || index !in episodeLabels.indices) return
        val channel = PhonePlayerBridge.channel ?: return
        watchDownloadSheet?.dismiss()
        watchDownloadSheet = PhoneWatchDownloadSheet(this, channel, sessionId, index,
            watchPanel?.row(index)?.heading ?: episodeLabels[index],
            intent.getIntExtra(PhonePlayerIntent.EXTRA_ACCENT, getColor(R.color.phone_player_accent)),
            PhonePlayerBridge.watchDataFor(sessionId), fullscreenIcon("download")).also { it.show() }
    }

    private fun showWatchEpisodeMenu(index: Int) {
        if (!isPortraitCard() || index !in episodeLabels.indices) return
        val channel = PhonePlayerBridge.channel ?: return
        val session = sessionId
        channel.invokeMethod("watchEpisodeState", mapOf("sessionId" to session, "index" to index), object : io.flutter.plugin.common.MethodChannel.Result {
            override fun success(result: Any?) {
                if (!uiAlive() || session != sessionId || !isPortraitCard()) return
                val state = result as? Map<*, *> ?: return
                val watched = state["watched"] == true
                watchPanel?.setWatched(index, watched)
                val canPlay = watchPanel?.row(index)?.unavailable.isNullOrEmpty()
                val labels = mutableListOf(getString(if (watched) R.string.phone_player_watch_mark_unwatched else R.string.phone_player_watch_mark_watched))
                if (canPlay) labels.add(getString(R.string.phone_player_watch_play_mirror))
                PhonePlayerSheet(this@PhonePlayerActivity)
                    .setTitle(watchPanel?.row(index)?.heading ?: episodeLabels[index])
                    .setItems(labels.toTypedArray()) { _, action ->
                        if (action == 0) setWatchEpisodeWatched(index, !watched) else chooseWatchEpisodeMirror(index)
                    }.showForPlayer()
            }
            override fun error(code: String, message: String?, details: Any?) { if (uiAlive()) toast(getString(R.string.phone_player_watch_update_failed)) }
            override fun notImplemented() {}
        })
    }

    private fun setWatchEpisodeWatched(index: Int, watched: Boolean) {
        PhonePlayerBridge.channel?.invokeMethod("setWatchEpisodeWatched", mapOf("sessionId" to sessionId, "index" to index, "watched" to watched), object : io.flutter.plugin.common.MethodChannel.Result {
            override fun success(result: Any?) {
                if (!uiAlive()) return
                if (result == true) watchPanel?.setWatched(index, watched)
                else toast(getString(R.string.phone_player_watch_update_failed))
            }
            override fun error(code: String, message: String?, details: Any?) { if (uiAlive()) toast(getString(R.string.phone_player_watch_update_failed)) }
            override fun notImplemented() {}
        })
    }

    private fun chooseWatchEpisodeMirror(index: Int) {
        val channel = PhonePlayerBridge.channel ?: return
        val generation = mediaGeneration
        val waiting = android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setMessage(R.string.phone_player_watch_loading_mirrors).create()
        var canceled = false
        waiting.setOnCancelListener { canceled = true }
        waiting.show()
        PhoneWatchMotion.enter(waiting)
        channel.invokeMethod("watchEpisodeMirrors", mapOf("sessionId" to sessionId, "index" to index), object : io.flutter.plugin.common.MethodChannel.Result {
            override fun success(result: Any?) {
                waiting.dismiss()
                if (canceled || !uiAlive() || generation != mediaGeneration || !isPortraitCard()) return
                val choices = mapList(result)
                if (choices.isEmpty()) { toast(getString(R.string.phone_player_error_load)); return }
                val labels = choices.mapIndexed { i, source -> (source["label"] as? String).orEmpty().ifBlank { "Server ${i + 1}" } }
                PhonePlayerSheet(this@PhonePlayerActivity)
                    .setTitle(R.string.phone_player_watch_play_mirror)
                    .setItems(labels.toTypedArray()) { _, which ->
                        if (!uiAlive() || generation != mediaGeneration) return@setItems
                        val selected = choices[which].toMutableMap()
                        if (index == loadedEpisodeIndex && playbackStarted) selected["positionMs"] = player?.currentPosition ?: 0L
                        sendProgress()
                        player?.pause()
                        if (index != loadedEpisodeIndex) resetZoom()
                        mirrors = choices
                        val nextGeneration = ++mediaGeneration
                        handler.removeCallbacks(resolveTimeout)
                        attemptedUrls.clear()
                        switching = true
                        applyResolved(index, selected, nextGeneration)
                        refreshWatchInfo()
                    }.showForPlayer()
            }
            override fun error(code: String, message: String?, details: Any?) { waiting.dismiss(); if (!canceled && uiAlive()) toast(getString(R.string.phone_player_error_load)) }
            override fun notImplemented() { waiting.dismiss() }
        })
    }

    private fun android.app.AlertDialog.Builder.showForPlayer(): android.app.AlertDialog =
        show().also { if (isPortraitCard()) PhoneWatchMotion.enter(it) }

    private fun showComingSoon() {
        handler.removeCallbacks(hideRunnable)
        PhonePlayerSheet(this)
            .setTitle(getString(R.string.phone_player_watch_comments))
            .setMessage(getString(R.string.phone_player_watch_coming_soon))
            .setPositiveButton(android.R.string.ok, null)
            .setOnDismissListener { bumpControls() }
            .showForPlayer()
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
        if (loadedEpisodeIndex != currentIndex) autoSkipped.clear()
        skipsRequested = false
        skipSegments = emptyList()
        updateSegmentButton(null)
        playbackStarted = false
        subtitlePreferenceApplied = false
        pendingAddonSubtitleId = null
        currentUrl = url
        seekPreview.setSource(url, headers)
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
        val upstream = DefaultDataSource.Factory(this, httpFactory)
        var dataSource: androidx.media3.datasource.DataSource.Factory = upstream
        if (PhonePlaybackCache.supports(url, mime)) {
            if (playbackDiskCache == null && intent.getBooleanExtra(PhonePlayerIntent.EXTRA_DISK_CACHE, false)) {
                playbackDiskCache = try {
                    val bytes = intent.getIntExtra(PhonePlayerIntent.EXTRA_DISK_CACHE_GB, 2)
                        .coerceIn(1, 20) * 1024L * 1024 * 1024
                    PhonePlaybackCache.acquire(this, bytes)
                } catch (_: Exception) { null }
            }
            val nativeMb = if (intent.getBooleanExtra(PhonePlayerIntent.EXTRA_NATIVE_CACHE, false)) {
                minOf(intent.getIntExtra(PhonePlayerIntent.EXTRA_NATIVE_CACHE_MB, 128).coerceIn(32, 512),
                    PhonePlaybackCache.nativeLimitMb(this))
            } else 0
            dataSource = PhonePlaybackCache.factory(upstream, url, headers, playbackDiskCache, nativeMb * 1024 * 1024)
        }
        val sourceFactory = DefaultMediaSourceFactory(dataSource)
        currentSourceFactory = sourceFactory
        p.setMediaSource(sourceFactory.createMediaSource(builder.build()))
        loadedEpisodeIndex = currentIndex
        if (positionMs > 0) p.seekTo(positionMs)
        p.prepare()
        p.playWhenReady = true
        handler.removeCallbacks(startTimeout)
        handler.postDelayed(startTimeout, 30_000L)
        if (intent.getBooleanExtra(PhonePlayerIntent.EXTRA_STREMIO_SUBTITLES, false)) {
            PhonePlayerBridge.channel?.invokeMethod("rememberStremioLink", mapOf(
                "sessionId" to sessionId, "index" to currentIndex, "url" to url,
            ))
        }
    }

    private fun showEpisodeMenu() {
        if (isMovie || episodeLabels.isEmpty() || episodePanel?.isShowing == true) return
        handler.removeCallbacks(hideRunnable)
        val episodes = watchPanel?.episodes
            ?: PhoneWatchEpisode.from(PhonePlayerBridge.watchDataFor(sessionId), episodeLabels)
        episodePanel = PhoneEpisodePanel(
            this, episodes, currentIndex,
            intent.getStringExtra(PhonePlayerIntent.EXTRA_COVER).orEmpty(),
            PhonePlayerIntent.headersFromArray(intent.getStringArrayExtra(PhonePlayerIntent.EXTRA_COVER_HEADERS)),
            intent.getIntExtra(PhonePlayerIntent.EXTRA_ACCENT, getColor(R.color.phone_player_accent)),
            ::loadEpisode,
        ).apply {
            setOnDismissListener {
                episodePanel = null
                bumpControls()
            }
            show()
            if (!isPortraitCard()) {
                window?.decorView?.systemUiVisibility =
                    this@PhonePlayerActivity.window.decorView.systemUiVisibility
            }
        }
    }

    /** Ask Dart for [index]'s stream, then play it. */
    private fun loadEpisode(index: Int) {
        if (index < 0 || index >= episodeCount || switching) return
        resetZoom()
        val generation = ++mediaGeneration
        attemptedUrls.clear()
        refreshedForbiddenLinks = false
        val ch = PhonePlayerBridge.channel ?: return
        val p = player
        sendProgress()
        p?.pause() // don't leave the old episode running under the spinner
        playbackStarted = false
        updateSegmentButton(null)
        handler.removeCallbacks(startTimeout)
        switching = true
        if (!everPlayed) {
            showLoading(episodeLabels.getOrNull(index))
        } else {
            // Miniplayer-contained switch (MPV watch-page parity): the page and
            // chrome stay up with the new episode's header while the source
            // resolves — no fullscreen backdrop. The index moves first so a
            // retry/failover during the switch targets the new episode
            // (progress for the old one was already saved above).
            currentIndex = index
            episodeText.text = episodeLabels.getOrNull(index) ?: ""
            loadingEpisode.text = episodeText.text
            updateEpisodeNavigation()
            refreshWatchInfo()
            bumpControls()
            setBuffering(true)
        }
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
        // A tap mid-load otherwise showed nothing until the stream itself
        // started — this request queues behind that same in-flight resolve
        // on the JS engine's one-at-a-time lane (see sourcesFor on the Dart
        // side), so a plain spinner-only wait looked like the tap did
        // nothing. Open feedback immediately instead of waiting on it.
        val index = currentIndex
        val generation = mediaGeneration
        var canceled = false
        val waiting = android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setMessage(R.string.phone_player_watch_loading_mirrors).create()
        waiting.setOnCancelListener { canceled = true }
        waiting.show()
        PhoneWatchMotion.enter(waiting)
        ch.invokeMethod(
            "sourcesFor",
            mapOf("index" to index, "sessionId" to sessionId),
            object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) {
                    waiting.dismiss()
                    if (canceled || !uiAlive() || currentIndex != index || mediaGeneration != generation) return
                    val choices = mapList(result)
                    if (choices.isEmpty()) {
                        toast("Couldn't load sources")
                        bumpControls()
                        return
                    }
                    val labels = choices.mapIndexed { i, source ->
                        val label = (source["label"] as? String).orEmpty()
                            .ifBlank { "Server ${i + 1}" }
                        val quality = (source["quality"] as? String).orEmpty()
                        if (quality.isEmpty() || label.contains(quality)) label
                        else "$label · $quality"
                    }.toTypedArray()
                    val selected = choices.indexOfFirst { it["url"] == currentUrl }
                    PhonePlayerSheet(this@PhonePlayerActivity)
                        .setTitle(getString(R.string.phone_player_title_sources))
                        .setSingleChoiceItems(labels, selected) { dialog, which ->
                            dialog.dismiss()
                            if (which != selected && currentIndex == index && mediaGeneration == generation) {
                                playMirror(choices[which])
                            }
                        }
                        .setOnDismissListener { bumpControls() }
                        .showForPlayer().listView.setOnItemLongClickListener { _, _, which, _ ->
                            val url = choices.getOrNull(which)?.get("url") as? String
                            if (!url.isNullOrEmpty()) {
                                val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("Video link", url))
                                toast("Link copied")
                            }
                            true
                        }
                }

                override fun error(code: String, msg: String?, details: Any?) {
                    waiting.dismiss()
                    if (canceled || !uiAlive() || currentIndex != index || mediaGeneration != generation) return
                    toast("Couldn't load sources")
                    bumpControls()
                }

                override fun notImplemented() {
                    waiting.dismiss()
                    if (canceled || !uiAlive() || currentIndex != index || mediaGeneration != generation) return
                    toast("Couldn't load sources")
                    bumpControls()
                }
            },
        )
    }

    private fun failover(forbidden: Boolean = false) {
        if (failoverInFlight || engineFallbackRequested) return
        val channel = PhonePlayerBridge.channel
        // A torrent can never play in ExoPlayer — yield to mpv even when the
        // auto-switch toggle is off. Mirrors Dart isTorrentUrl (magnet: / .torrent).
        val u = currentUrl.trim().lowercase()
        val unplayableTorrent = u.startsWith("magnet:") || u.endsWith(".torrent")
        if ((!intent.getBooleanExtra(PhonePlayerIntent.EXTRA_AUTO_ENGINE_FALLBACK, false) && !unplayableTorrent) || channel == null) {
            failoverMirrors(forbidden)
            return
        }
        failoverInFlight = true
        val generation = mediaGeneration
        val index = currentIndex
        val url = currentUrl
        fun complete(switchEngine: Boolean) {
            if (!uiAlive()) return
            failoverInFlight = false
            if (generation != mediaGeneration || index != currentIndex || url != currentUrl) return
            if (switchEngine) {
                engineFallbackRequested = true
                finish()
            } else {
                failoverMirrors(forbidden)
            }
        }
        channel.invokeMethod("tryOtherPlayer", mapOf(
            "sessionId" to sessionId, "index" to index, "url" to url,
            "positionMs" to (player?.currentPosition ?: 0L),
        ), object : io.flutter.plugin.common.MethodChannel.Result {
            override fun success(result: Any?) = complete(result == true)
            override fun error(code: String, message: String?, details: Any?) = complete(false)
            override fun notImplemented() = complete(false)
        })
    }

    private fun failoverMirrors(forbidden: Boolean, refresh: Boolean = false) {
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
            mapOf("index" to requestedIndex, "sessionId" to sessionId, "refresh" to refresh),
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
                    if (next == null && forbidden && !refreshedForbiddenLinks) {
                        refreshedForbiddenLinks = true
                        failoverMirrors(forbidden, refresh = true)
                    } else if (next == null) {
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
        PhonePlayerSheet(this)
            .setTitle(getString(R.string.phone_player_title_subtitles))
            .setItems(labels.toTypedArray()) { _, which ->
                selectTextTrack(picks[which])
            }
            .setOnDismissListener { bumpControls() }
            .showForPlayer()
    }

    private fun showSpeedMenu() {
        val p = player ?: return
        handler.removeCallbacks(hideRunnable)
        val rates = floatArrayOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f, 2.5f, 3f, 4f, 5f)
        val checked = rates.indexOfFirst { kotlin.math.abs(it - p.playbackParameters.speed) < 0.001f }
        val labels = rates.map { "${it}x" }.toTypedArray()
        PhonePlayerSheet(this)
            .setTitle(getString(R.string.phone_player_title_speed))
            .setChips(labels, checked) { dialog, which ->
                dialog.dismiss()
                p.playbackParameters = PlaybackParameters(rates[which])
                bumpControls()
            }
            .setOnDismissListener { bumpControls() }
            .showForPlayer()
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
        reportSubtitleChoice(pick)
        bumpControls()
    }

    /** Tell Dart the user's subtitle pick so the show remembers it. 'off'
     * when track selection is disabled, else the track's BCP-47 language. */
    private fun reportSubtitleChoice(pick: TrackSelectionOverride?) {
        val ch = PhonePlayerBridge.channel ?: return
        var choice = "off"
        val tracks = player?.currentTracks
        val group = tracks?.groups?.find { it.mediaTrackGroup == pick?.mediaTrackGroup }
        val lang = pick?.trackIndices?.firstOrNull()?.let {
            group?.getTrackFormat(it)?.language
        }
        if (pick != null && lang.isNullOrBlank()) return
        if (!lang.isNullOrEmpty()) choice = lang
        ch.invokeMethod(
            "rememberSubtitle",
            mapOf("sessionId" to sessionId, "choice" to choice),
        )
    }

    private fun renderSubtitleCues(cues: List<Cue>) {
        playerView.subtitleView?.setCues(
            SubtitleCuePositioning.position(cues, subtitlePosition, 0.0533f * subtitleScale),
        )
    }

    private fun applySubtitleStyle() {
        playerView.subtitleView?.apply {
            setStyle(CaptionStyleCompat(
                subtitleForeground,
                subtitleBackground,
                android.graphics.Color.TRANSPARENT,
                subtitleEdgeType,
                subtitleEdgeColor,
                subtitleTypeface,
            ))
            setFractionalTextSize(0.0533f * subtitleScale)
        }
        player?.currentCues?.let { renderSubtitleCues(it.cues) }
    }

    private fun updateSubtitleFont(path: String?) {
        if (subtitleFontPath == path) return
        subtitleFontPath = path
        subtitleTypeface = path?.let {
            runCatching { android.graphics.Typeface.createFromFile(it) }.getOrNull()
        }
    }

    internal fun updateSubtitleStyle(
        scale: Float, position: Int, foreground: Int, background: Int,
        edgeType: Int, edgeColor: Int, fontPath: String?,
    ) {
        subtitleScale = scale.coerceIn(0.25f, 5f)
        subtitlePosition = position.coerceIn(0, 100)
        subtitleForeground = foreground
        subtitleBackground = background
        subtitleEdgeType = edgeType
        subtitleEdgeColor = edgeColor
        updateSubtitleFont(fontPath)
        applySubtitleStyle()
    }

    private fun showSubtitleStyle() {
        if (subtitleStyleDialog?.isShowing != true) {
            subtitleStyleDialog = PhonePlayerBridge.openSubtitleStyle(this)
        }
    }

    private fun showTracksMenu() {
        val p = player ?: return
        handler.removeCallbacks(hideRunnable)
        val tracks = p.currentTracks
        val audio = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
        val text = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
        val audioTracks = audio.flatMap { g -> (0 until g.length).map { g to it } }
        val textTracks = text.flatMap { g -> (0 until g.length).map { g to it } }
        val labels = mutableListOf<String>()
        val versionFor = mutableListOf<String?>()
        // Live Sub/Dub switch, routed back through Dart's catalogue
        // resolution (same episode, position retained). Only when the title
        // actually offers more than one version.
        if (categories.size > 1) {
            for (cat in categories) {
                val name = when (cat.lowercase()) {
                    "dub" -> getString(R.string.phone_player_version_dub)
                    else -> getString(R.string.phone_player_version_sub)
                }
                val mark = if (cat == currentCategory) " ✓" else ""
                labels += "Version: $name$mark"
                versionFor += cat
            }
        }
        labels += "Audio: Auto"
        versionFor += null
        // audioPicks[0] ("Auto") sits at this label index; tracks follow.
        val audioBase = labels.size - 1
        val addonSubtitles = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_STREMIO_SUBTITLES, false)
        val audioPicks = mutableListOf<TrackSelectionOverride?>(null)
        for ((g, i) in audioTracks) {
            val f = g.getTrackFormat(i)
            labels += "Audio: ${f.label ?: f.language ?: "Track ${labels.size}"}"
            versionFor += null
            audioPicks += TrackSelectionOverride(g.mediaTrackGroup, i)
        }
        val textBase = labels.size
        labels += "Subtitles: Off"
        versionFor += null
        val textPicks = mutableListOf<TrackSelectionOverride?>(null)
        for ((g, i) in textTracks) {
            val f = g.getTrackFormat(i)
            labels += "Subtitles: ${f.label ?: f.language ?: "Track ${labels.size}"}"
            versionFor += null
            textPicks += TrackSelectionOverride(g.mediaTrackGroup, i)
        }
        val addonRow = if (addonSubtitles) labels.size else -1
        if (addonSubtitles) {
            labels += "Addon subtitles…"
            versionFor += null
        }
        val styleRow = labels.size
        labels += getString(R.string.phone_player_subtitle_style)
        versionFor += null
        val selectedRows = mutableSetOf<Int>()
        if (categories.size > 1) categories.indexOf(currentCategory).takeIf { it >= 0 }?.let { selectedRows += it }
        val audioIndex = audioTracks.indexOfFirst { (group, index) ->
            group.isTrackSelected(index) && p.trackSelectionParameters.overrides.containsKey(group.mediaTrackGroup)
        }
        selectedRows += audioBase + audioIndex + 1
        val textIndex = if (p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)) -1
            else textTracks.indexOfFirst { (group, index) -> group.isTrackSelected(index) }
        selectedRows += textBase + textIndex + 1
        PhonePlayerSheet(this)
            .setTitle(getString(R.string.phone_player_title_tracks))
            .setTrackItems(labels.toTypedArray(), audioBase, textBase, selectedRows) { _, which ->
                if (which == styleRow) {
                    showSubtitleStyle()
                    return@setTrackItems
                }
                if (which == addonRow) {
                    showAddonSubtitles()
                    return@setTrackItems
                }
                val version = versionFor[which]
                if (version != null) {
                    if (version != currentCategory) switchCategory(version)
                    else bumpControls()
                } else if (which < textBase) {
                    selectAudioTrack(audioPicks[which - audioBase])
                } else {
                    selectTextTrack(textPicks[which - textBase])
                }
            }
            .setOnDismissListener { bumpControls() }
            .showForPlayer()
    }

    private fun showAddonSubtitles() {
        val ch = PhonePlayerBridge.channel ?: return
        val generation = mediaGeneration
        val url = currentUrl
        val loading = PhonePlayerSheet(this)
            .setMessage("Loading addon subtitles…")
            .setNegativeButton(android.R.string.cancel, null)
            .showForPlayer()
        ch.invokeMethod("addonSubtitles", mapOf(
            "sessionId" to sessionId, "index" to currentIndex, "url" to url,
        ), object : io.flutter.plugin.common.MethodChannel.Result {
            override fun success(result: Any?) {
                val visible = loading.isShowing
                loading.dismiss()
                if (!visible || !uiAlive() || generation != mediaGeneration || currentUrl != url) return
                val data = result as? Map<*, *>
                fun strings(key: String) = (data?.get(key) as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                val tracks = subtitlesFrom(strings("subUrls"), strings("subLangs"), strings("subLabels"), strings("subFormats"), emptyList())
                if (tracks.isEmpty()) {
                    toast("No addon subtitles found. Try again.")
                    return
                }
                PhonePlayerSheet(this@PhonePlayerActivity)
                    .setTitle(getString(R.string.phone_player_title_subtitles))
                    .setItems(tracks.map { it.label ?: it.language ?: "Subtitle" }.toTypedArray()) { _, which ->
                        if (!uiAlive() || generation != mediaGeneration || currentUrl != url) return@setItems
                        val p = player ?: return@setItems
                        val item = p.currentMediaItem ?: return@setItems
                        val factory = currentSourceFactory ?: return@setItems
                        val selected = tracks[which].buildUpon()
                            .setId(tracks[which].uri.toString())
                            .setSelectionFlags(C.SELECTION_FLAG_DEFAULT).build()
                        val remaining = item.localConfiguration?.subtitleConfigurations.orEmpty()
                            .filter { it.uri != selected.uri }
                            .map { it.buildUpon().setSelectionFlags(0).build() }
                        val position = p.currentPosition
                        val playing = p.playWhenReady
                        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                            .setPreferredTextLanguage(selected.language)
                            .build()
                        subtitlePreferenceApplied = true
                        pendingAddonSubtitleId = selected.id
                        val addonChoice = selected.language
                        if (!addonChoice.isNullOrEmpty()) {
                            PhonePlayerBridge.channel?.invokeMethod(
                                "rememberSubtitle",
                                mapOf("sessionId" to sessionId, "choice" to addonChoice),
                            )
                        }
                        val updated = item.buildUpon().setSubtitleConfigurations(remaining + selected).build()
                        p.setMediaSource(factory.createMediaSource(updated), position)
                        p.prepare()
                        p.playWhenReady = playing
                    }
                    .setOnDismissListener { bumpControls() }
                    .showForPlayer()
            }
            override fun error(code: String, message: String?, details: Any?) {
                loading.dismiss()
                if (uiAlive() && generation == mediaGeneration) toast("Could not load addon subtitles. Try again.")
            }
            override fun notImplemented() { loading.dismiss() }
        })
    }

    /** Switch Sub/Dub in place: Dart re-resolves the SAME episode through the
     * normal catalogue path and hands back a payload whose position is the
     * one sent up — never episode one, never zero. */
    private fun switchCategory(category: String) {
        val ch = PhonePlayerBridge.channel ?: return
        handler.removeCallbacks(hideRunnable)
        setBuffering(true)
        val generation = ++mediaGeneration
        val position = player?.currentPosition ?: 0L
        ch.invokeMethod(
            "switchCategory",
            mapOf(
                "category" to category,
                "index" to currentIndex,
                "positionMs" to position,
            ),
            object : io.flutter.plugin.common.MethodChannel.Result {
                @Suppress("UNCHECKED_CAST")
                override fun success(result: Any?) {
                    if (!uiAlive()) return
                    setBuffering(false)
                    val m = result as? Map<String, Any?>
                    if (generation != mediaGeneration || m == null) {
                        if (m == null) toast(getString(R.string.phone_player_error_load))
                        else bumpControls()
                        return
                    }
                    currentCategory = category
                    applyResolved(currentIndex, m, generation)
                }

                override fun error(code: String, msg: String?, details: Any?) {
                    if (!uiAlive()) return
                    setBuffering(false)
                    toast(getString(R.string.phone_player_error_load))
                    bumpControls()
                }

                override fun notImplemented() {
                    if (!uiAlive()) return
                    setBuffering(false)
                    bumpControls()
                }
            },
        )
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
        PhonePlayerSheet(this)
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
            .showForPlayer()
    }

    private fun toggleRotation() {
        requestedOrientation = if (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE)
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        bumpControls()
    }

    /** "Ambient player screen" setting, flipped live from the More menu.
     * [updateOrientationLayout] already knows how to apply/clear the glow and
     * start/stop sampling, so re-running it is the whole live-apply step. */
    private fun toggleAmbient() {
        ambientEnabled = !ambientEnabled
        updateOrientationLayout()
        bumpControls()
        PhonePlayerBridge.channel?.invokeMethod("setAmbientPlayer", mapOf("value" to ambientEnabled))
    }

    private fun cycleDisplayMode() {
        val modes = intArrayOf(AspectRatioFrameLayout.RESIZE_MODE_FIT,
            AspectRatioFrameLayout.RESIZE_MODE_FILL, AspectRatioFrameLayout.RESIZE_MODE_ZOOM)
        resizeIndex = (resizeIndex + 1) % modes.size
        playerView.resizeMode = modes[resizeIndex]
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
        PhonePlayerSheet(this)
            .setTitle(getString(R.string.phone_player_menu_display))
            .setSingleChoiceItems(labels, resizeIndex) { dialog, which ->
                dialog.dismiss()
                resizeIndex = which
                playerView.resizeMode = modes[which]
                bumpControls()
            }
            .setOnDismissListener { bumpControls() }
            .showForPlayer()
    }

    private fun pickCast() {
        castManager?.pickDevice()
        bumpControls()
    }

    private fun showMoreMenu() {
        handler.removeCallbacks(hideRunnable)
        val portrait = isPortraitCard()
        val portraitShortcuts = setOf("tracks", "sources", "episodes", "rotate")
        val items = mutableListOf<Triple<String, Int, () -> Unit>>()
        fun add(label: Int, icon: Int, shortcut: String? = null, action: () -> Unit) {
            if (shortcut != null) {
                val duplicate = if (portrait) {
                    shortcut in portraitShortcuts
                } else {
                    val id = controlSpec(shortcut)?.first
                    id != null && controls.findViewById<View>(id)?.visibility == View.VISIBLE
                }
                if (duplicate) return
            }
            items += Triple(getString(label), icon, action)
        }

        add(R.string.phone_player_title_speed, R.drawable.phone_player_speed, "speed") { showSpeedMenu() }
        add(R.string.phone_player_title_tracks, R.drawable.phone_player_tracks, "tracks") { showTracksMenu() }
        add(R.string.phone_player_title_quality, R.drawable.phone_player_quality, "quality") { showQualityMenu() }
        add(R.string.phone_player_menu_sources, R.drawable.phone_player_sources, "sources") { showSourceMenu() }
        if (!isMovie) {
            add(R.string.phone_player_menu_episodes, R.drawable.phone_player_episodes, "episodes") { showEpisodeMenu() }
        }
        add(R.string.phone_player_menu_display, R.drawable.phone_player_display, "fit") { showDisplayMenu() }
        add(R.string.phone_player_menu_rotate, R.drawable.phone_player_rotate, "rotate") { toggleRotation() }
        if (castSupported) {
            add(R.string.phone_player_menu_cast, R.drawable.phone_player_cast, "cast") { pickCast() }
        }
        if (!portrait) {
            add(R.string.phone_player_arrange_controls, android.R.drawable.ic_menu_preferences, "settings") {
                showControlArrangement()
            }
        }
        add(R.string.phone_player_menu_switch_player, R.drawable.phone_player_sources) { requestManualSwitch() }
        val ambientLabel = if (ambientEnabled) R.string.phone_player_menu_ambient_on
            else R.string.phone_player_menu_ambient_off
        add(ambientLabel, R.drawable.phone_player_display) { toggleAmbient() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            add(R.string.phone_player_menu_pip, R.drawable.ic_pip_play) { pip.enter(null) }
        }
        add(R.string.phone_player_menu_info, R.drawable.phone_player_info, "info") { showInfo() }
        val dialog = PhonePlayerSheet(this)
            .setItemIcons(items.map { it.second })
            .setTitle(getString(R.string.phone_player_title_more))
            .setItems(items.map { it.first }.toTypedArray()) { dialog, index ->
                dialog.dismiss()
                items[index].third()
            }
            .setOnDismissListener {
                moreDialog = null
                bumpControls()
            }
            .showForPlayer()
        moreDialog = dialog
    }

    /** User-tapped Switch Player — bypasses the auto-fallback toggle. */
    private fun requestManualSwitch() {
        if (failoverInFlight || engineFallbackRequested) return
        val channel = PhonePlayerBridge.channel ?: return
        channel.invokeMethod("tryOtherPlayer", mapOf(
            "sessionId" to sessionId, "index" to currentIndex, "url" to currentUrl,
            "positionMs" to (player?.currentPosition ?: 0L), "manual" to true,
        ), object : io.flutter.plugin.common.MethodChannel.Result {
            override fun success(result: Any?) {
                if (result == true) { engineFallbackRequested = true; finish() }
            }
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        })
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
        PhonePlayerSheet(this)
            .setTitle(getString(R.string.phone_player_title_playback_info))
            .setMessage(message)
            .setPositiveButton(android.R.string.ok, null)
            .setOnDismissListener { bumpControls() }
            .showForPlayer()
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
                "index" to loadedEpisodeIndex,
                "sessionId" to sessionId,
                "positionMs" to p.currentPosition.coerceAtLeast(0L),
                "durationMs" to p.duration,
                "playing" to (p.playWhenReady && p.playbackState != Player.STATE_ENDED),
                "actualPlaying" to p.isPlaying,
                "completed" to (p.playbackState == Player.STATE_ENDED),
            ),
        )
    }

    private fun sendProgress() {
        val p = player ?: return
        if (!playbackStarted || p.duration <= 0) return
        PhonePlayerBridge.channel?.invokeMethod(
            "saveProgress",
            mapOf(
                "index" to loadedEpisodeIndex,
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

        val pullColors = ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_selected), intArrayOf()),
            intArrayOf(
                intent.getIntExtra(PhonePlayerIntent.EXTRA_ACCENT, getColor(R.color.phone_player_accent)),
                android.graphics.Color.WHITE,
            ),
        )
        rotationPullArrow = TextView(this).apply {
            setTextColor(pullColors)
            textSize = 16f
        }
        rotationPullProgress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progressTintList = pullColors
            progressBackgroundTintList = ColorStateList.valueOf(0x40FFFFFF)
        }
        rotationPullHint = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            background = pill()
            setPadding(dp(10), dp(6), dp(10), dp(6))
            visibility = View.GONE
            addView(rotationPullArrow)
            addView(rotationPullProgress, LinearLayout.LayoutParams(dp(48), dp(3)).apply {
                marginStart = dp(6)
            })
        }
        root.addView(rotationPullHint, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL,
        ).apply { topMargin = dp(16) })

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
                progressTintList = ColorStateList.valueOf(0xFFFF4D57L.toInt())
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

        holdSpeedBadge = TextView(this).apply {
            text = "2×"
            setTextColor(android.graphics.Color.WHITE)
            textSize = 13.5f
            typeface = android.graphics.Typeface.create("sans-serif-medium", 0)
            gravity = Gravity.CENTER_VERTICAL
            background = pill().apply {
                cornerRadius = dp(13).toFloat()
                setColor(0x80000000.toInt())
            }
            setPaddingRelative(dp(10), dp(6), dp(12), dp(6))
            val icon = getDrawable(R.drawable.ic_seek_forward)?.apply {
                setBounds(0, 0, dp(18), dp(18))
            }
            setCompoundDrawablesRelative(icon, null, null, null)
            compoundDrawablePadding = dp(5)
            visibility = View.GONE
        }
        root.addView(
            holdSpeedBadge,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL,
            ).apply { topMargin = dp(12) },
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
        val action = ev.actionMasked
        val holding = speedBeforeHold != null
        when (action) {
            MotionEvent.ACTION_DOWN -> {
                singleFingerRotation = true
                downX = ev.x
                downY = ev.y
                rotationDownX = ev.rawX
                rotationDownY = ev.rawY
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                singleFingerRotation = false
                restoreSpeedAfterHold()
                resetRotationPull()
            }
            MotionEvent.ACTION_CANCEL -> {
                restoreSpeedAfterHold()
                resetRotationPull()
            }
            MotionEvent.ACTION_UP -> restoreSpeedAfterHold()
        }
        val rotationY = ev.rawY - rotationDownY
        val rotationX = kotlin.math.abs(ev.rawX - rotationDownX)
        if (isPortraitCard() || (holding && action != MotionEvent.ACTION_POINTER_DOWN)) {
            taps.onTouchEvent(ev)
            val up = -rotationY
            val pullingUp = singleFingerRotation && !holding && up > rotationX
            if (action == MotionEvent.ACTION_MOVE && !holding) {
                if (pullingUp && up >= dp(12)) updateRotationPull(v, rotationY)
                else resetRotationPull()
            }
            if (action == MotionEvent.ACTION_UP && !holding) {
                val commit = pullingUp && up >= dp(ROTATION_PULL_DISTANCE_DP)
                resetRotationPull(animate = !commit)
                if (commit) {
                    toggleRotation()
                } else {
                    v.performClick()
                }
            }
            return
        }
        // Let the detector see the move or second finger that claims the gesture,
        // so it cancels the pending long press before swipe or pinch takes over.
        if (action == MotionEvent.ACTION_CANCEL ||
            (!pinchActive && gestureMode == 0 &&
                (pinchEndAt == 0L || android.os.SystemClock.uptimeMillis() - pinchEndAt > 300L))
        ) {
            taps.onTouchEvent(ev)
        }
        when (action) {
            MotionEvent.ACTION_DOWN -> {
                pointers.clear()
                pointers[ev.getPointerId(0)] = ev.x to ev.y
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
                        gestureMode = when {
                            kotlin.math.abs(dx) > kotlin.math.abs(dy) -> 1
                            singleFingerRotation &&
                                resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE &&
                                downX >= v.width / 3f && downX <= v.width * 2 / 3f -> 3
                            else -> 2
                        }
                        if (gestureMode == 1) startHSeek()
                        if (gestureMode == 2) startVSlide(ev.x)
                    }
                } else if (gestureMode == 1) {
                    updateHSeek(ev.x)
                } else if (gestureMode == 2) {
                    updateVSlide(ev.y)
                }
                if (gestureMode == 3 && singleFingerRotation && rotationY > rotationX) {
                    updateRotationPull(v, rotationY)
                } else if (gestureMode == 3) {
                    resetRotationPull()
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
                val returnToPortrait = gestureMode == 3 && singleFingerRotation &&
                    action == MotionEvent.ACTION_UP && rotationY >= dp(ROTATION_PULL_DISTANCE_DP) &&
                    rotationY > rotationX
                if (gestureMode == 3 && action == MotionEvent.ACTION_UP) {
                    resetRotationPull(animate = !returnToPortrait)
                }
                if (pinchActive) endPinch()
                pointers.clear()
                gestureMode = 0
                // Only a real release is a "click"; firing on every ACTION_MOVE
                // spams TalkBack with a click event per drag sample.
                if (returnToPortrait) showWatchPage()
                else if (action == MotionEvent.ACTION_UP) v.performClick()
            }
        }
    }

    private fun rotationMotionEnabled() = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
        android.animation.ValueAnimator.areAnimatorsEnabled()

    private fun updateRotationPull(video: View, distance: Float) {
        val progress = (kotlin.math.abs(distance) * 100 / dp(ROTATION_PULL_DISTANCE_DP)).toInt().coerceAtMost(100)
        video.animate().cancel()
        if (rotationMotionEnabled()) {
            video.translationY = (distance * .5f).coerceIn(-dp(36).toFloat(), dp(36).toFloat())
        }
        rotationPullArrow.text = if (distance < 0) "↑" else "↓"
        rotationPullArrow.isSelected = progress == 100
        rotationPullProgress.isSelected = progress == 100
        rotationPullProgress.progress = progress
        rotationPullHint.visibility = View.VISIBLE
    }

    private fun resetRotationPull(animate: Boolean = true) {
        if (!::rotationPullHint.isInitialized) return
        val video = findViewById<View>(R.id.player_root)
        if (animate && rotationPullHint.visibility != View.VISIBLE) return
        rotationPullHint.visibility = View.GONE
        video.animate().cancel()
        if (animate && rotationMotionEnabled() && video.translationY != 0f) {
            video.animate().translationY(0f).setDuration(160).start()
        } else {
            video.translationY = 0f
        }
    }

    private fun restoreSpeedAfterHold() {
        val previous = speedBeforeHold ?: return
        speedBeforeHold = null
        player?.playbackParameters = previous
        holdSpeedBadge.visibility = View.GONE
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
                if (isPortraitCard()) btnPlay.setImageResource(resource)
                else btnPlay.setImageDrawable(fullscreenIcon(
                    if (resource == R.drawable.ic_pip_pause) "pause" else "play") ?: getDrawable(resource))
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

    private fun updateSegmentFill() {
        segmentFill.clipBounds = android.graphics.Rect(
            0, 0, (segmentFill.width * segmentProgress / 10_000), segmentFill.height,
        )
    }

    private fun segmentControlsVisible() = controls.visibility == View.VISIBLE && !controlsHiding

    private fun updateSegmentButton(segment: SkipSegment?) {
        if (activeSegment != segment) {
            activeSegment = segment
            segmentTimer.cancel()
            segmentProgress = 0
            updateSegmentFill()
            if (segment != null) {
                segmentLabel.setText(segment.label)
                segmentFill.setText(segment.label)
                segmentButton.contentDescription = getString(segment.label)
            }
        }
        if (segment == null) {
            segmentButton.visibility = View.GONE
            return
        }

        val controlsVisible = segmentControlsVisible()
        if (segmentProgress < 10_000) {
            if (segmentTimer.isPaused) segmentTimer.resume()
            else if (!segmentTimer.isStarted) segmentTimer.start()
        }
        segmentButton.visibility = if (controlsVisible || segmentProgress < 10_000) {
            View.VISIBLE
        } else View.GONE

        val params = segmentButton.layoutParams as FrameLayout.LayoutParams
        val bottom = dp(if (isPortraitCard()) 52 else if (controlsVisible) 120 else 28)
        if (params.bottomMargin != bottom) {
            params.bottomMargin = bottom
            segmentButton.layoutParams = params
        }
    }

    private fun syncSkipSegments(p: ExoPlayer, position: Long, duration: Long) {
        if (!playbackStarted || switching || p.playbackState != Player.STATE_READY ||
            loadedEpisodeIndex != currentIndex || loadingOverlay.visibility == View.VISIBLE
        ) {
            updateSegmentButton(null)
            return
        }
        if (!skipsRequested) {
            skipsRequested = true
            val sourceFactory = currentSourceFactory
            val index = currentIndex
            val generation = mediaGeneration
            PhonePlayerBridge.channel?.invokeMethod(
                "skipsFor",
                mapOf("sessionId" to sessionId, "index" to index, "durationMs" to duration),
                object : io.flutter.plugin.common.MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (!uiAlive() || player !== p || currentSourceFactory !== sourceFactory ||
                            index != currentIndex || generation != mediaGeneration) return
                        val response = result as? Map<*, *> ?: return
                        showSegmentButton = response["manual"] == true
                        skipSegments = (response["segments"] as? List<*>).orEmpty().mapNotNull {
                            val row = it as? Map<*, *> ?: return@mapNotNull null
                            val start = (row["start"] as? Number)?.toLong() ?: return@mapNotNull null
                            val end = (row["end"] as? Number)?.toLong() ?: return@mapNotNull null
                            if (start < 0 || end <= start || end > duration) return@mapNotNull null
                            val label = when (row["type"]) {
                                "recap" -> R.string.phone_player_skip_recap
                                "ed", "mixed-ed" -> R.string.phone_player_skip_ending
                                else -> R.string.phone_player_skip_opening
                            }
                            SkipSegment(start, end, label, row["auto"] == true)
                        }
                    }
                    override fun error(code: String, message: String?, details: Any?) {}
                    override fun notImplemented() {}
                },
            )
        }
        val auto = if (p.isPlaying && !scrubbing) skipSegments.firstOrNull {
            it.auto && it.start !in autoSkipped && position >= it.start && position < it.end - 1_000
        } else null
        if (auto != null) {
            autoSkipped.add(auto.start)
            p.seekTo(auto.end)
            updateSegmentButton(null)
            return
        }
        updateSegmentButton(if (showSegmentButton && !controlsLocked && !isInPictureInPictureMode && !scrubbing) {
            skipSegments.firstOrNull { position >= it.start && position < it.end }
        } else null)
    }

    private fun syncProgress() {
        val p = player ?: return
        val d = p.duration
        if (d > 0) {
            val pos = p.currentPosition
            syncSkipSegments(p, pos, d)
            if (!scrubbing) {
                // Keep the drawable at the current position when rotation replaces the track.
                seek.progress = (pos * 1000 / d).toInt().coerceIn(0, 1000)
                timeText.text = if (isPortraitCard()) fmt(pos).padStart(5, '0') + " / " + fmt(d).padStart(5, '0') else fmt(pos) + " / " + fmt(d)
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
        if (controlsLocked) { unlockControl?.visibility = View.VISIBLE; return }
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
        if (controlsLocked) return
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

    private fun renderersFactory(): RenderersFactory {
        val mode = intent.getStringExtra(PhonePlayerIntent.EXTRA_DECODER_MODE)
            ?: if (intent.getBooleanExtra(PhonePlayerIntent.EXTRA_SW_DECODE, false)) "sw" else "auto"
        val factory = if (mode == "direct") {
            DefaultRenderersFactory(this)
        } else {
            NextRenderersFactory(this).setExtensionRendererMode(
                if (mode == "sw") DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
                else DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON,
            )
        }
        return factory.setEnableDecoderFallback(true)
    }

    /** Tell Dart the session ended, with where it ended. Runs exactly once. */
    private fun reportClosed(
        positionMs: Long = player?.currentPosition ?: 0L,
        durationMs: Long = (player?.duration ?: 0L).coerceAtLeast(0L),
    ) {
        if (reported) return
        reported = true
        PhonePlayerBridge.channel?.invokeMethod(
            "playerClosed",
            mapOf(
                "sessionId" to sessionId,
                PhonePlayerIntent.RESULT_POSITION to positionMs,
                PhonePlayerIntent.RESULT_DURATION to durationMs,
                "engineFallback" to engineFallbackRequested,
                "url" to currentUrl,
                PhonePlayerIntent.RESULT_EP_INDEX to loadedEpisodeIndex,
                PhonePlayerIntent.RESULT_PLAYBACK_ERROR to playbackError,
            ),
        )
    }

    // A phone gets interrupted by calls and notifications; the TV player never
    // had to handle this. Pause on the way out and leave resuming to the user.
    override fun onPause() {
        resetRotationPull(animate = false)
        if (subtitleStyleDialog?.isShowing == true) PhonePlayerBridge.setSubtitleOverlayResumed(false)
        restoreSpeedAfterHold()
        orientationObserver?.disable()
        super.onPause()
        sendProgress()
        // PiP is still "paused" as an Activity but must keep playing.
        if (!isInPictureInPictureMode) player?.pause()
        updateKeepScreenOn()
        handler.removeCallbacks(ticker)
        if (segmentTimer.isRunning) segmentTimer.pause()
    }

    // The ticker is stopped in onPause so it doesn't keep polling a paused
    // player and writing to invisible views while backgrounded; restart it
    // here rather than in onCreate.
    override fun onResume() {
        super.onResume()
        if (subtitleStyleDialog?.isShowing == true) PhonePlayerBridge.setSubtitleOverlayResumed(true)
        orientationObserver?.enable()
        updateKeepScreenOn()
        handler.post(ticker)
    }

    // Android 8.0–11 have no auto-enter API, so arm PiP on Home; 12+ uses
    // setAutoEnterEnabled and would double-trigger.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPipEnabled &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            playbackStarted &&
            !isInPictureInPictureMode
        ) {
            pip.enter(null)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            pip.applyParams()
            // Only the system window chrome should be visible in PiP.
            updateSegmentButton(null)
            controls.visibility = View.GONE
        } else {
            bumpControls()
        }
    }

    override fun onDestroy() {
        if (::seekPreview.isInitialized) seekPreview.close()
        segmentTimer.cancel()
        episodePanel?.setOnDismissListener(null)
        episodePanel?.dismiss()
        episodePanel = null
        subtitleStyleDialog?.dismiss()
        subtitleStyleDialog = null
        pip.unregister()
        watchDownloadSheet?.dismiss()
        watchDownloadSheet = null
        orientationObserver?.disable()
        orientationObserver = null
        watchPanel?.close()
        stopAmbient()
        PhonePlayerBridge.clearWatchData(sessionId)
        val finalPosition = player?.currentPosition ?: 0L
        val finalDuration = (player?.duration ?: 0L).coerceAtLeast(0L)
        if (!engineFallbackRequested) reportClosed()
        handler.removeCallbacksAndMessages(null)
        moreDialog?.setOnDismissListener(null)
        moreDialog?.dismiss()
        moreDialog = null
        active = null
        castManager?.release()
        castManager = null
        player?.release()
        player = null
        if (engineFallbackRequested) reportClosed(finalPosition, finalDuration)
        if (playbackDiskCache != null) {
            PhonePlaybackCache.release()
            playbackDiskCache = null
        }
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (controlsLocked) { setControlsLocked(false); return }
        if (loadingActions.visibility == View.VISIBLE) { finish(); return }
        if (controls.visibility == View.VISIBLE) { hideControls(); return }
        if (showWatchPage()) return
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    private fun showWatchPage(): Boolean {
        if (watchPage) return false
        watchPage = true
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        updateOrientationLayout()
        return true
    }

    private fun goImmersive() {
        val portraitPage = isPortraitCard()
        // The activity theme is Theme.Black.NoTitleBar.Fullscreen, which
        // never draws system bar backgrounds — statusBarColor below is a
        // no-op without this, so the bar stayed opaque black regardless of
        // what we set it to.
        androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)
        // The activity theme also hides the status bar through a window flag.
        if (portraitPage) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        }
        @Suppress("DEPRECATION")
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        @Suppress("DEPRECATION")
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // A contrast scrim would paint a flat band over the glow in
            // exactly the place mpv shows it through.
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        val root = findViewById<View>(R.id.watch_root)
        val statusBarId = resources.getIdentifier("status_bar_height", "dimen", "android")
        val topInset = if (portraitPage && statusBarId > 0) resources.getDimensionPixelSize(statusBarId) else 0
        root?.setPadding(root.paddingLeft, topInset, root.paddingRight, root.paddingBottom)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = if (portraitPage) {
            // LIGHT_STATUS_BAR/LIGHT_NAVIGATION_BAR deliberately absent:
            // white icons read over the ambient wash, like mpv.
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        } else (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            )
    }
}
