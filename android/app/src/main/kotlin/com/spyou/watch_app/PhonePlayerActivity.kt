package com.spyou.watch_app

import android.app.Activity
import android.content.pm.ActivityInfo
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
    private var controlsHiding = false

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        keepScreenOn = intent.getBooleanExtra(PhonePlayerIntent.EXTRA_KEEP_SCREEN_ON, true)
        if (keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
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
                        e.x < third -> seekBy(-seekMs)
                        e.x > third * 2 -> seekBy(seekMs)
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
            override fun onPlaybackStateChanged(state: Int) {
                updateKeepScreenOn()
                loading.visibility =
                    if (state == Player.STATE_BUFFERING) View.VISIBLE else View.GONE
                if (state == Player.STATE_READY) {
                    playbackError = false
                    playbackStarted = true
                }
                if (state == Player.STATE_ENDED &&
                    autoplayNext &&
                    !switching &&
                    currentIndex + 1 < episodeCount
                ) {
                    loadEpisode(currentIndex + 1)
                }
            }

            override fun onTracksChanged(tracks: Tracks) {
                applySubtitlePreference(tracks)
            }

            override fun onPlayerError(error: PlaybackException) {
                playbackError = true
                loading.visibility = View.GONE
                failover()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                updateKeepScreenOn()
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
        val generation = ++mediaGeneration
        attemptedUrls.clear()
        val ch = PhonePlayerBridge.channel ?: return
        val p = player
        sendProgress()
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

    private fun failSwitch() {
        switching = false
        loading.visibility = View.GONE
        android.widget.Toast
            .makeText(this, "Couldn't load that episode", android.widget.Toast.LENGTH_SHORT)
            .show()
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
        currentIndex = index
        episodeText.text = m["episodeLabel"] as? String ?: episodeLabels.getOrNull(index) ?: ""
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
        loading.visibility = View.VISIBLE
        ch.invokeMethod(
            "sourcesFor",
            mapOf("index" to currentIndex),
            object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) {
                    if (!uiAlive()) return
                    loading.visibility = View.GONE
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
                    loading.visibility = View.GONE
                    toast("Couldn't load sources")
                    bumpControls()
                }

                override fun notImplemented() {
                    if (!uiAlive()) return
                    loading.visibility = View.GONE
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
        loading.visibility = View.VISIBLE
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
                        toast("All sources failed")
                        finish()
                    } else {
                        playMirror(next, position, generation)
                    }
                }

                override fun error(code: String, msg: String?, details: Any?) {
                    if (!uiAlive()) return
                    if (generation != mediaGeneration) return
                    failoverInFlight = false
                    toast("All sources failed")
                    finish()
                }

                override fun notImplemented() {
                    if (!uiAlive()) return
                    if (generation != mediaGeneration) return
                    failoverInFlight = false
                    toast("All sources failed")
                    finish()
                }
            },
        )
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
        val rates = floatArrayOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f)
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
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        } else {
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        bumpControls()
    }

    private fun cycleDisplayMode() {
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
        resizeIndex = (resizeIndex + 1) % modes.size
        playerView.resizeMode = modes[resizeIndex]
        toast(labels[resizeIndex])
        bumpControls()
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
            { cycleDisplayMode() },
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
        val rowColor = androidx.core.content.ContextCompat.getColor(
            this,
            R.color.phone_player_on_surface
        )
        val adapter = object : android.widget.BaseAdapter() {
            override fun getCount(): Int = labels.size
            override fun getItem(position: Int): Any = labels[position]
            override fun getItemId(position: Int): Long = position.toLong()
            override fun getView(position: Int, convertView: View?, parent: android.view.ViewGroup?): View {
                val row = android.widget.LinearLayout(this@PhonePlayerActivity).apply {
                    orientation = android.widget.LinearLayout.HORIZONTAL
                    gravity = android.view.Gravity.CENTER_VERTICAL
                    minimumHeight = (48 * density).toInt()
                    setPadding(
                        (24 * density).toInt(),
                        (12 * density).toInt(),
                        (24 * density).toInt(),
                        (12 * density).toInt()
                    )
                }
                val icon = android.widget.ImageView(this@PhonePlayerActivity).apply {
                    setImageResource(icons[position])
                    imageTintList = android.content.res.ColorStateList.valueOf(rowColor)
                    contentDescription = null
                    val size = (24 * density).toInt()
                    layoutParams = android.widget.LinearLayout.LayoutParams(size, size)
                }
                val text = android.widget.TextView(this@PhonePlayerActivity).apply {
                    text = labels[position]
                    textSize = 16f
                    setTextColor(rowColor)
                    val params = android.widget.LinearLayout.LayoutParams(
                        android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                        android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                    params.marginStart = (16 * density).toInt()
                    layoutParams = params
                }
                row.addView(icon)
                row.addView(text)
                return row
            }
        }
        android.app.AlertDialog.Builder(this, R.style.PhonePlayerDialog)
            .setTitle(getString(R.string.phone_player_title_more))
            .setAdapter(adapter) { dialog, which ->
                dialog.dismiss()
                actions[which]()
            }
            .setOnDismissListener { bumpControls() }
            .show()
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
        active = null
        castManager?.release()
        castManager = null
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
