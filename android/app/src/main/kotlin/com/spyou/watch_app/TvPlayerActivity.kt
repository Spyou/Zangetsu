package com.spyou.watch_app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
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
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.DefaultTimeBar
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import io.flutter.plugin.common.MethodChannel
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.NextRenderersFactory

/**
 * Fully-native TV video player. The SAME ExoPlayer + [PlayerView] as the legacy
 * [ExoPlayerView], but hosted directly in a real Activity window (SurfaceView →
 * straight to the display, no Flutter compositing layer that can black out the
 * picture). This is the CloudStream model.
 *
 * The control overlay ([R.layout.tv_player]) is fully custom and key-driven:
 *  - OK (tap)      → play / pause
 *  - OK (hold)     → 2× fast-forward while held
 *  - ◀ / ▶         → seek ∓10 s
 *  - ▼             → focus the button row (Episodes / Audio & Subs / Next);
 *                    ◀ ▶ then move along it, OK activates, ▲ / Back leaves it
 *  - Back          → leave the row, else exit (returning the position to Flutter)
 *
 * Phase 1 features (resume, Continue-Watching) are preserved; the button-row
 * actions are wired in later phases via a native→Dart resolution bridge.
 */
@UnstableApi
class TvPlayerActivity : Activity() {

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_HEADERS = "headers"        // flat String[]: k,v,k,v
        const val EXTRA_TITLE = "title"
        const val EXTRA_EP_LABEL = "episodeLabel"
        const val EXTRA_POSITION = "positionMs"    // start (resume) position
        const val EXTRA_MIME = "mimeType"
        const val EXTRA_SUB_URLS = "subUrls"
        const val EXTRA_SUB_LANGS = "subLangs"
        const val EXTRA_SUB_LABELS = "subLabels"
        const val EXTRA_SW_DECODE = "softwareDecoding"
        const val EXTRA_ACCENT = "accentColor"
        const val EXTRA_SPEED = "defaultSpeed"
        const val EXTRA_VOLUME = "volumeBoost"
        const val EXTRA_SUB_SCALE = "subtitleScale"
        const val EXTRA_SUB_COLOR = "subtitleColor"
        const val EXTRA_SUB_BG = "subtitleBgOpacity"
        const val EXTRA_EP_LABELS = "episodeLabels"
        const val EXTRA_EP_COUNT = "episodeCount"
        const val EXTRA_START_INDEX = "startIndex"
        const val EXTRA_CATEGORY = "category"
        const val EXTRA_AVAIL_CATS = "availableCategories"
        // Result extras read back in MainActivity.onActivityResult.
        const val RESULT_POSITION = "positionMs"
        const val RESULT_DURATION = "durationMs"
        const val RESULT_EP_INDEX = "episodeIndex"
        private const val TAG = "TvPlayer"
        private const val SEEK_MS = 10_000L
        private const val AUTO_HIDE_MS = 4_000L
        private const val HOLD_MS = 500L
        private const val DEFAULT_ACCENT = 0xFFFF4D5E.toInt()
        private const val UNFOCUSED_PILL = 0x59101014 // subtle dark glass (premium)
    }

    private var player: ExoPlayer? = null
    private var reported = false
    private var accent = DEFAULT_ACCENT

    private var currentIndex = 0
    private var episodeCount = 1
    private var episodeLabels: Array<String> = emptyArray()
    private var category = "sub"
    private var availableCategories: List<String> = emptyList()
    private var episodeSources: List<Map<String, Any?>> = emptyList() // mirrors for the Server picker
    private var currentUrl: String? = null
    private var switching = false // guards against overlapping episode switches

    private data class Skip(val start: Long, val end: Long, val type: String)
    private var skipIntervals: List<Skip> = emptyList()
    private var skipsFetchedFor = -1 // episode index skips were fetched for
    private var activeSkipEnd = -1L  // end of the interval currently offered

    private lateinit var root: View
    private lateinit var playerView: PlayerView
    private lateinit var loading: View
    private lateinit var controls: View
    private lateinit var timeBar: DefaultTimeBar
    private lateinit var positionText: TextView
    private lateinit var durationText: TextView
    private lateinit var centerIcon: ImageView
    private lateinit var seekIndicator: TextView
    private lateinit var speedBadge: TextView
    private lateinit var skipButton: TextView
    private lateinit var buttonRow: View
    private lateinit var btnEpisodes: TextView
    private lateinit var btnQuality: TextView
    private lateinit var btnSources: TextView
    private lateinit var btnAudioSubs: TextView
    private lateinit var btnNext: TextView

    private lateinit var menuPanel: View
    private lateinit var menuContent: android.widget.LinearLayout

    private var controlsVisible = false
    private var focusZone = 0 // 0 = none (OK=play/pause, ◀▶=seek), 1 = top actions, 2 = bottom
    private val rowFocused get() = focusZone != 0
    private var speedEngaged = false
    private var menuOpen = false
    private var menuOpener: View? = null // the row button that opened the panel
    // Land focus on the option the user last picked (else the current selection,
    // else the first row) when a menu (re)opens — not always the first row.
    private var firstSelectedRow: View? = null
    private var focusTarget: View? = null
    private var lastFocusLabel: String? = null
    private var speed = 1f
    private var volumePercent = 100
    private var loudness: android.media.audiofx.LoudnessEnhancer? = null
    // While seeking, the accumulating target position (−1 = not seeking). Lets a
    // burst of ◀▶ presses add up (and the bar/preview jump instantly) instead of
    // each press re-reading the not-yet-updated player position.
    private var seekTarget = -1L

    private val handler = Handler(Looper.getMainLooper())
    private val hideRunnable = Runnable { hideControls() }
    private val engage2x = Runnable { engageSpeed() }
    private val hideSeekIndicator = Runnable { seekIndicator.visibility = View.GONE }
    // Commit the accumulated seek once the user stops pressing (debounced), so a
    // fast burst becomes one seek instead of a storm.
    private val commitSeek = Runnable {
        val t = seekTarget
        seekTarget = -1L
        if (t >= 0) player?.seekTo(t)
    }
    private val ticker = object : Runnable {
        override fun run() {
            updateProgress()
            updateSkip()
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        goImmersive()

        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrEmpty()) { finish(); return }
        accent = intent.getIntExtra(EXTRA_ACCENT, DEFAULT_ACCENT)
        episodeCount = intent.getIntExtra(EXTRA_EP_COUNT, 1)
        currentIndex = intent.getIntExtra(EXTRA_START_INDEX, 0)
        episodeLabels = intent.getStringArrayExtra(EXTRA_EP_LABELS) ?: emptyArray()
        category = intent.getStringExtra(EXTRA_CATEGORY) ?: "sub"
        availableCategories = intent.getStringArrayExtra(EXTRA_AVAIL_CATS)?.toList() ?: emptyList()

        setContentView(R.layout.tv_player)
        bindViews()
        styleControls()
        // Android 13+ (the tester's Bravia) routes Back through the predictive-back
        // dispatcher — the app opts in app-wide via enableOnBackInvokedCallback=true
        // — which finishes this Activity WITHOUT ever calling dispatchKeyEvent or
        // onBackPressed. Register a callback so Back runs our own hierarchy
        // (close menu → hide controls → exit) instead of blindly exiting.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                android.window.OnBackInvokedCallback { handleBack() },
            )
        }
        updateEpisodeUi()

        playerView.useController = false
        playerView.keepScreenOn = true

        val exo = ExoPlayer.Builder(this, renderersFactory()).build()
        player = exo
        playerView.player = exo

        // Apply saved defaults: playback speed, volume boost, subtitle style.
        speed = intent.getFloatExtra(EXTRA_SPEED, 1f)
        exo.playbackParameters = PlaybackParameters(speed)
        applyVolume(intent.getIntExtra(EXTRA_VOLUME, 100))
        applySubtitleStyle()

        exo.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() {
                Log.i(TAG, "onRenderedFirstFrame — native surface is showing video")
            }
            override fun onPlayerError(error: PlaybackException) {
                Log.e(TAG, "onPlayerError: ${error.errorCodeName} — ${error.message}", error)
                android.widget.Toast.makeText(
                    this@TvPlayerActivity,
                    "Playback error: ${error.errorCodeName}",
                    android.widget.Toast.LENGTH_LONG,
                ).show()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                updatePlayPauseIcon()
                // Keep the controls (and the pause glyph) on screen while paused so
                // it's obvious playback is stopped; resume re-arms the auto-hide.
                if (isPlaying) bumpControls() else { showControls(); cancelAutoHide() }
            }
            override fun onPlaybackStateChanged(state: Int) {
                updatePlayPauseIcon()
                if (!switching) {
                    loading.visibility =
                        if (state == Player.STATE_BUFFERING) View.VISIBLE else View.GONE
                }
                // Duration is known once ready → fetch AniSkip for this episode.
                if (state == Player.STATE_READY && skipsFetchedFor != currentIndex) fetchSkips()
                // Autoplay the next episode when this one finishes.
                if (state == Player.STATE_ENDED && !switching && currentIndex < episodeCount - 1) {
                    loadEpisode(currentIndex + 1)
                }
            }
        })

        // First episode: stream data comes straight from the intent (Dart resolved
        // it before launching). Later switches come from the bridge.
        loadStream(
            url,
            headersFromIntent(),
            subtitleConfigs(),
            intent.getStringExtra(EXTRA_MIME),
            intent.getLongExtra(EXTRA_POSITION, 0L),
        )
        fetchSources() // populate the Server picker for the current episode

        handler.post(ticker)
        bumpControls()
    }

    /** Loads a resolved stream into the current player and starts it. Reused for
     *  the first episode and every switch. */
    private fun loadStream(
        url: String,
        headers: Map<String, String>?,
        subs: List<MediaItem.SubtitleConfiguration>?,
        mime: String?,
        positionMs: Long,
    ) {
        val p = player ?: return
        currentUrl = url
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
        if (!headers.isNullOrEmpty()) httpFactory.setDefaultRequestProperties(headers)
        val builder = MediaItem.Builder().setUri(url)
        if (!mime.isNullOrEmpty()) builder.setMimeType(mime)
        if (subs != null) builder.setSubtitleConfigurations(subs)
        seekTarget = -1L
        p.setMediaSource(DefaultMediaSourceFactory(httpFactory).createMediaSource(builder.build()))
        if (positionMs > 0) p.seekTo(positionMs)
        p.prepare()
        p.playWhenReady = true
    }

    // ── Episode switching (via the native→Dart bridge) ───────────────────────
    private fun loadEpisode(index: Int) {
        if (index < 0 || index >= episodeCount || switching) return
        val bridge = MainActivity.tvBridge ?: return
        // Persist the outgoing episode before leaving it.
        val p = player
        if (p != null && p.duration > 0) {
            bridge.invokeMethod(
                "saveProgress",
                mapOf(
                    "index" to currentIndex,
                    "positionMs" to p.currentPosition,
                    "durationMs" to p.duration,
                ),
            )
        }
        p?.pause() // don't keep the old episode running under the spinner
        switching = true
        loading.visibility = View.VISIBLE
        bridge.invokeMethod(
            "resolveEpisode",
            mapOf("index" to index, "category" to category),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    val m = result as? Map<String, Any?>
                    if (m == null) { switching = false; loading.visibility = View.GONE; toastFail() }
                    else applyResolved(index, m)
                }
                override fun error(code: String, msg: String?, details: Any?) {
                    switching = false; loading.visibility = View.GONE; toastFail()
                }
                override fun notImplemented() {
                    switching = false; loading.visibility = View.GONE; toastFail()
                }
            },
        )
    }

    private fun applyResolved(index: Int, m: Map<String, Any?>) {
        val url = m["url"] as? String
        if (url.isNullOrEmpty()) { switching = false; loading.visibility = View.GONE; toastFail(); return }
        @Suppress("UNCHECKED_CAST")
        val headers = m["headers"] as? Map<String, String>
        val mime = m["mimeType"] as? String
        val positionMs = (m["positionMs"] as? Number)?.toLong() ?: 0L
        currentIndex = index
        skipIntervals = emptyList()
        skipsFetchedFor = -1
        hideSkip()
        loadStream(url, headers, subsFromMap(m["subtitles"]), mime, positionMs)
        updateEpisodeUi()
        fetchSources() // refresh the Server picker for the new episode/category
        bumpControls()
        switching = false // new media's buffering now drives the spinner
    }

    private fun subsFromMap(raw: Any?): List<MediaItem.SubtitleConfiguration>? {
        @Suppress("UNCHECKED_CAST")
        val list = raw as? List<Map<String, Any?>> ?: return null
        if (list.isEmpty()) return null
        return list.mapNotNull { s ->
            val u = s["url"] as? String ?: return@mapNotNull null
            MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(u))
                .setMimeType(if (u.lowercase().contains(".srt")) MimeTypes.APPLICATION_SUBRIP else MimeTypes.TEXT_VTT)
                .setLanguage(s["lang"] as? String)
                .setLabel(s["label"] as? String)
                .build()
        }
    }

    private fun updateEpisodeUi() {
        val label = episodeLabels.getOrNull(currentIndex) ?: ""
        findViewById<TextView>(R.id.episode_label).apply {
            text = label
            visibility = if (label.isBlank()) View.GONE else View.VISIBLE
        }
        val hasNext = currentIndex < episodeCount - 1
        btnNext.isEnabled = hasNext
        btnNext.isFocusable = hasNext
        btnNext.alpha = if (hasNext) 1f else 0.35f
    }

    private fun toastFail() = android.widget.Toast.makeText(
        this, "Couldn't load that episode", android.widget.Toast.LENGTH_SHORT,
    ).show()

    /** Cache the current episode's mirror list for the Server picker. */
    private fun fetchSources() {
        val bridge = MainActivity.tvBridge ?: return
        bridge.invokeMethod(
            "sourcesFor",
            mapOf("index" to currentIndex, "category" to category),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    episodeSources = (result as? List<Map<String, Any?>>) ?: emptyList()
                }
                override fun error(code: String, msg: String?, details: Any?) {}
                override fun notImplemented() {}
            },
        )
    }

    /** Fetch AniSkip intro/outro intervals for the current episode (anime only). */
    private fun fetchSkips() {
        val bridge = MainActivity.tvBridge ?: return
        val p = player ?: return
        skipsFetchedFor = currentIndex
        bridge.invokeMethod(
            "skipsFor",
            mapOf("index" to currentIndex, "durationMs" to p.duration.coerceAtLeast(0)),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    val list = result as? List<Map<String, Any?>> ?: emptyList()
                    skipIntervals = list.mapNotNull {
                        val s = (it["start"] as? Number)?.toLong() ?: return@mapNotNull null
                        val e = (it["end"] as? Number)?.toLong() ?: return@mapNotNull null
                        Skip(s, e, (it["type"] as? String) ?: "op")
                    }
                }
                override fun error(code: String, msg: String?, details: Any?) {}
                override fun notImplemented() {}
            },
        )
    }

    /** Show/hide the Skip pill based on the current position (called each tick). */
    private fun updateSkip() {
        val p = player ?: return
        if (menuOpen || switching) {
            if (skipButton.visibility == View.VISIBLE) skipButton.visibility = View.GONE
            return
        }
        val pos = p.currentPosition
        val iv = skipIntervals.firstOrNull { pos >= it.start && pos < it.end }
        if (iv == null) {
            if (skipButton.visibility == View.VISIBLE) hideSkip()
            return
        }
        activeSkipEnd = iv.end
        skipButton.text = if (iv.type == "ed") "Skip Ending" else "Skip Intro"
        if (skipButton.visibility != View.VISIBLE) {
            skipButton.visibility = View.VISIBLE
            // Auto-focus once so OK skips immediately. The D-pad can then move off it
            // and back — ▼ from the video reaches it, ▲ from the button row too.
            if (!rowFocused && !menuOpen) skipButton.requestFocus()
        }
    }

    private fun hideSkip() {
        val wasFocused = skipButton.isFocused
        skipButton.visibility = View.GONE
        activeSkipEnd = -1L
        if (wasFocused) root.requestFocus()
    }

    private fun isTorrentUrl(url: String): Boolean {
        val u = url.lowercase()
        return u.startsWith("magnet:") || u.endsWith(".torrent") || u.contains(".torrent?")
    }

    /** Switch to a different mirror for the current episode, keeping position. A
     *  magnet/.torrent is streamed via Dart (TorrentService → local URL) first. */
    private fun loadSource(i: Int) {
        val s = episodeSources.getOrNull(i) ?: return
        val url = s["url"] as? String ?: return
        @Suppress("UNCHECKED_CAST")
        val headers = s["headers"] as? Map<String, String>
        val subs = subsFromMap(s["subtitles"])
        val mime = s["mimeType"] as? String
        val pos = player?.currentPosition ?: 0L
        if (!isTorrentUrl(url)) { loadStream(url, headers, subs, mime, pos); return }
        loading.visibility = View.VISIBLE
        MainActivity.tvBridge?.invokeMethod(
            "resolveTorrent",
            mapOf("url" to url),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val local = result as? String
                    if (local == null) { loading.visibility = View.GONE; toastFail() }
                    else loadStream(local, headers, subs, mime, pos)
                }
                override fun error(code: String, msg: String?, details: Any?) {
                    loading.visibility = View.GONE; toastFail()
                }
                override fun notImplemented() {
                    loading.visibility = View.GONE; toastFail()
                }
            },
        )
    }

    /** Sub ⇄ Dub: re-resolve the current episode in the other category. */
    private fun switchCategory(cat: String) {
        if (cat == category || switching) return
        val bridge = MainActivity.tvBridge ?: return
        val p = player
        if (p != null && p.duration > 0) {
            bridge.invokeMethod(
                "saveProgress",
                mapOf("index" to currentIndex, "positionMs" to p.currentPosition, "durationMs" to p.duration),
            )
        }
        p?.pause()
        switching = true
        loading.visibility = View.VISIBLE
        category = cat
        bridge.invokeMethod(
            "resolveEpisode",
            mapOf("index" to currentIndex, "category" to cat),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    @Suppress("UNCHECKED_CAST")
                    val m = result as? Map<String, Any?>
                    if (m == null) { switching = false; loading.visibility = View.GONE; toastFail() }
                    else applyResolved(currentIndex, m)
                }
                override fun error(code: String, msg: String?, details: Any?) {
                    switching = false; loading.visibility = View.GONE; toastFail()
                }
                override fun notImplemented() {
                    switching = false; loading.visibility = View.GONE; toastFail()
                }
            },
        )
    }

    // ── Options menu (Quality / Audio / Subtitles / Speed / Volume) ───────────
    private fun showPanel() {
        // Hide the transport controls so the panel reads cleanly over the video.
        controls.visibility = View.GONE
        controlsVisible = false
        cancelAutoHide()
        menuPanel.visibility = View.VISIBLE
        menuPanel.scrollTo(0, 0)
        menuPanel.alpha = 0f
        menuPanel.animate().alpha(1f).setDuration(150).start()
        menuOpen = true
    }

    /** Builds the menu content and shows the panel, landing focus on the last
     *  chosen / currently-selected option instead of always the first row. */
    private fun showMenu(opener: View, build: () -> Unit) {
        menuOpener = opener
        firstSelectedRow = null
        focusTarget = null
        menuContent.removeAllViews()
        build()
        showPanel()
        menuContent.post {
            (focusTarget ?: firstSelectedRow ?: firstFocusable(menuContent))?.requestFocus()
        }
    }

    /** Quality — HLS variants or the distinct per-source resolutions. */
    private fun openQualityMenu() = showMenu(btnQuality) { buildQualityMenu() }

    /** Sources — the full resolved stream/mirror list. */
    private fun openSourcesMenu() = showMenu(btnSources) { buildSourcesMenu() }

    /** Audio / Sub-Dub / Subtitles / Speed / Volume. */
    private fun openAvMenu() = showMenu(btnAudioSubs) { buildAvMenu() }

    /** The "Episodes" list — jump to any episode via the same bridge switch. */
    private fun openEpisodes() {
        menuOpener = btnEpisodes
        firstSelectedRow = null
        focusTarget = null
        menuContent.removeAllViews()
        sectionHeader("Episodes")
        for (i in 0 until episodeCount) {
            val label = episodeLabels.getOrNull(i) ?: "Episode ${i + 1}"
            option(label, selected = i == currentIndex) { if (i != currentIndex) loadEpisode(i) }
        }
        showPanel()
        // Land focus on the current episode (row index = currentIndex + 1 header).
        menuContent.post {
            val row = (currentIndex + 1).coerceIn(0, menuContent.childCount - 1)
            menuContent.getChildAt(row)?.requestFocus()
        }
    }

    private fun closeMenu() {
        menuOpen = false
        menuPanel.visibility = View.GONE
        menuContent.removeAllViews()
        bumpControls()
        (menuOpener ?: root).requestFocus()
    }

    private fun firstFocusable(group: android.view.ViewGroup): View? {
        for (i in 0 until group.childCount) {
            val c = group.getChildAt(i)
            if (c.isFocusable) return c
        }
        return null
    }

    /** Quality menu — mirrors the phone: adaptive HLS variants when the current
     *  stream is a multi-variant master, otherwise the distinct per-source
     *  resolutions (providers that ship one stream per quality). */
    private fun buildQualityMenu() {
        val p = player ?: return
        val groups = p.currentTracks.groups
        val video = groups.filter { it.type == C.TRACK_TYPE_VIDEO && it.isSupported }
        val videoTracks = video.flatMap { g -> (0 until g.length).map { g to it } }
            .filter { (g, i) -> g.isTrackSupported(i) }

        if (videoTracks.size > 1) {
            val overridden = p.trackSelectionParameters.overrides.keys.any {
                video.any { g -> g.mediaTrackGroup == it }
            }
            sectionHeader("Quality")
            option("Auto", selected = !overridden) {
                p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                    .clearOverridesOfType(C.TRACK_TYPE_VIDEO).build()
            }
            for ((g, i) in videoTracks.sortedByDescending { (g, i) -> g.getTrackFormat(i).height }) {
                val h = g.getTrackFormat(i).height
                option(if (h > 0) "${h}p" else "Track ${i + 1}",
                    selected = overridden && g.isTrackSelected(i)) {
                    applyOverride(C.TRACK_TYPE_VIDEO, g, i)
                }
            }
        } else {
            // Distinct per-source resolutions (mobile's sourceQualities).
            val seen = HashSet<String>()
            val perQuality = episodeSources.mapIndexedNotNull { i, s ->
                val q = (s["quality"] as? String)?.trim().orEmpty()
                if (q.isEmpty() || !seen.add(q)) null else q to i
            }
            if (perQuality.isNotEmpty()) {
                sectionHeader("Quality")
                for ((q, i) in perQuality) {
                    option(q, selected = (episodeSources.getOrNull(i)?.get("url") as? String) == currentUrl) {
                        loadSource(i)
                    }
                }
            }
        }

        if (menuContent.childCount == 0) {
            sectionHeader("Quality")
            option("Auto", selected = true) {}
        }
    }

    /** Sources menu — the full resolved stream/mirror list (mobile's Sources). */
    private fun buildSourcesMenu() {
        if (episodeSources.size > 1) {
            sectionHeader("Sources")
            episodeSources.forEachIndexed { i, s ->
                val label = (s["label"] as? String) ?: "Source ${i + 1}"
                option(label, selected = (s["url"] as? String) == currentUrl) { loadSource(i) }
            }
        } else {
            sectionHeader("Sources")
            option(episodeSources.firstOrNull()?.get("label") as? String ?: "Default", selected = true) {}
        }
    }

    /** The "Audio & Subs" button's menu. */
    private fun buildAvMenu() {
        val p = player ?: return
        val groups = p.currentTracks.groups

        // Audio tracks.
        addTrackSection("Audio", groups, C.TRACK_TYPE_AUDIO) { f, idx ->
            f.label ?: langName(f.language) ?: "Audio ${idx + 1}"
        }

        // Sub / Dub (Version).
        if (availableCategories.size > 1) {
            sectionHeader("Sub / Dub")
            for (c in availableCategories) {
                option(if (c == "dub") "Dub" else "Sub", selected = c == category) { switchCategory(c) }
            }
        }

        // Subtitles (+ Off).
        val text = groups.filter { it.type == C.TRACK_TYPE_TEXT }
        val textTracks = text.flatMap { g -> (0 until g.length).map { g to it } }
        if (textTracks.isNotEmpty()) {
            val textDisabled = p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
            sectionHeader("Subtitles")
            option("Off", selected = textDisabled) {
                p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                    .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
            }
            for ((g, i) in textTracks) {
                val f = g.getTrackFormat(i)
                val label = f.label ?: langName(f.language) ?: "Subtitle ${i + 1}"
                option(label, selected = !textDisabled && g.isTrackSelected(i)) {
                    applyOverride(C.TRACK_TYPE_TEXT, g, i)
                }
            }
        }

        // Playback speed.
        sectionHeader("Speed")
        for (s in listOf(0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f)) {
            option(if (s == 1.0f) "Normal" else "${s}×", selected = speed == s) {
                speed = s
                player?.playbackParameters = PlaybackParameters(s)
            }
        }

        // Volume boost.
        sectionHeader("Volume")
        for (v in listOf(100, 125, 150, 175, 200)) {
            option("$v%", selected = volumePercent == v) { applyVolume(v) }
        }
    }

    private fun addTrackSection(
        title: String,
        groups: List<Tracks.Group>,
        type: Int,
        label: (androidx.media3.common.Format, Int) -> String,
    ) {
        val gs = groups.filter { it.type == type && it.isSupported }
        val tracks = gs.flatMap { g -> (0 until g.length).map { g to it } }
        if (tracks.size <= 1) return
        sectionHeader(title)
        for ((g, i) in tracks) {
            option(label(g.getTrackFormat(i), i), selected = g.isTrackSelected(i)) {
                applyOverride(type, g, i)
            }
        }
    }

    private fun applyOverride(type: Int, g: Tracks.Group, trackIndex: Int) {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, trackIndex))
            .build()
    }

    private fun applyVolume(percent: Int) {
        volumePercent = percent.coerceIn(100, 200)
        val gainMb = (((volumePercent - 100) / 100f) * 600f).toInt()
        try {
            if (loudness == null) loudness = android.media.audiofx.LoudnessEnhancer(player!!.audioSessionId)
            loudness?.setTargetGain(gainMb)
            loudness?.enabled = gainMb > 0
        } catch (_: Exception) { /* effect unavailable on this device */ }
    }

    /** Style side-loaded + embedded subtitles from the saved prefs: scale, colour,
     *  optional background, black outline (readable on TV over any scene). */
    private fun applySubtitleStyle() {
        val scale = intent.getFloatExtra(EXTRA_SUB_SCALE, 1f)
        val fg = try {
            android.graphics.Color.parseColor(intent.getStringExtra(EXTRA_SUB_COLOR) ?: "#FFFFFFFF")
        } catch (_: Exception) { android.graphics.Color.WHITE }
        val bgAlpha = (intent.getFloatExtra(EXTRA_SUB_BG, 0f) * 255).toInt().coerceIn(0, 255)
        playerView.subtitleView?.apply {
            setApplyEmbeddedStyles(false)
            setApplyEmbeddedFontSizes(false)
            setStyle(
                CaptionStyleCompat(
                    fg,
                    android.graphics.Color.argb(bgAlpha, 0, 0, 0),
                    android.graphics.Color.TRANSPARENT,
                    CaptionStyleCompat.EDGE_TYPE_OUTLINE,
                    android.graphics.Color.BLACK,
                    null,
                ),
            )
            setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * scale)
        }
    }

    private fun langName(code: String?): String? {
        if (code.isNullOrBlank() || code == "und") return null
        return try {
            java.util.Locale(code).displayLanguage.ifBlank { code }
        } catch (_: Exception) { code }
    }

    private fun sectionHeader(title: String) {
        menuContent.addView(TextView(this).apply {
            text = title.uppercase()
            setTextColor(accent)
            textSize = 12.5f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            letterSpacing = 0.09f
            val t = if (menuContent.childCount == 0) dp(2) else dp(22)
            setPadding(dp(4), t, 0, dp(8))
        })
    }

    private fun option(label: String, selected: Boolean, onSelect: () -> Unit) {
        val row = TextView(this).apply {
            text = (if (selected) "✓   " else "     ") + label
            setTextColor(if (selected) android.graphics.Color.WHITE else 0xFFB6B6C0.toInt())
            textSize = 16.5f
            if (selected) setTypeface(typeface, android.graphics.Typeface.BOLD)
            isFocusable = true
            isFocusableInTouchMode = true
            setPadding(dp(16), dp(11), dp(16), dp(11))
            background = pillBg(0x00000000)
            setOnClickListener { lastFocusLabel = label; onSelect(); closeMenu() }
            onFocusChangeListener = View.OnFocusChangeListener { v, has ->
                v.background = pillBg(if (has) accent else 0x00000000)
                (v as TextView).setTextColor(
                    if (has) android.graphics.Color.WHITE
                    else if (selected) android.graphics.Color.WHITE else 0xFFB6B6C0.toInt()
                )
            }
        }
        if (selected && firstSelectedRow == null) firstSelectedRow = row
        if (label == lastFocusLabel) focusTarget = row
        menuContent.addView(
            row,
            android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
    }

    private fun pillBg(color: Int) = android.graphics.drawable.GradientDrawable().apply {
        cornerRadius = dp(12).toFloat()
        setColor(color)
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun bindViews() {
        root = findViewById(R.id.player_root)
        playerView = findViewById(R.id.player_view)
        loading = findViewById(R.id.loading)
        skipButton = findViewById(R.id.skip_button)
        menuPanel = findViewById(R.id.menu_panel)
        menuContent = findViewById(R.id.menu_content)
        controls = findViewById(R.id.controls)
        timeBar = findViewById(R.id.time_bar)
        positionText = findViewById(R.id.position)
        durationText = findViewById(R.id.duration)
        centerIcon = findViewById(R.id.center_icon)
        seekIndicator = findViewById(R.id.seek_indicator)
        speedBadge = findViewById(R.id.speed_badge)
        buttonRow = findViewById(R.id.button_row)
        btnEpisodes = findViewById(R.id.btn_episodes)
        btnQuality = findViewById(R.id.btn_quality)
        btnSources = findViewById(R.id.btn_sources)
        btnAudioSubs = findViewById(R.id.btn_audio_subs)
        btnNext = findViewById(R.id.btn_next)

        findViewById<TextView>(R.id.title).text = intent.getStringExtra(EXTRA_TITLE) ?: ""
        // episode_label is set by updateEpisodeUi (drives off episodeLabels).
    }

    private fun styleControls() {
        timeBar.setPlayedColor(accent)
        timeBar.setScrubberColor(accent)
        // Accent-tinted, clean loading spinner (premium, not the grey default).
        (loading as? android.widget.ProgressBar)?.indeterminateTintList =
            android.content.res.ColorStateList.valueOf(accent)
        // The seek bar is display-only on TV (◀▶ keys drive seeking), so it must
        // never steal focus from the button row.
        timeBar.isFocusable = false

        for (b in listOf(btnEpisodes, btnQuality, btnSources, btnAudioSubs, btnNext)) {
            b.isClickable = true
            // Focusable even in touch mode so requestFocus() works on emulators
            // (real TVs are always in D-pad/non-touch mode anyway).
            b.isFocusableInTouchMode = true
            applyPillFocus(b, false)
            b.onFocusChangeListener = View.OnFocusChangeListener { v, hasFocus ->
                applyPillFocus(v as TextView, hasFocus)
                if (hasFocus) cancelAutoHide()
            }
        }
        // Phase-2 wiring lands in later tasks; for now the buttons are focusable
        // and highlight, so the layout + D-pad model can be verified end to end.
        btnEpisodes.setOnClickListener { openEpisodes() }
        btnQuality.setOnClickListener { openQualityMenu() }
        btnSources.setOnClickListener { openSourcesMenu() }
        btnAudioSubs.setOnClickListener { openAvMenu() }
        btnNext.setOnClickListener { loadEpisode(currentIndex + 1) }

        skipButton.isFocusableInTouchMode = true
        applyPillFocus(skipButton, false)
        skipButton.onFocusChangeListener =
            View.OnFocusChangeListener { v, has -> applyPillFocus(v as TextView, has) }
        skipButton.setOnClickListener {
            if (activeSkipEnd > 0) { player?.seekTo(activeSkipEnd); seekTarget = -1L }
            hideSkip()
        }
    }

    private fun applyPillFocus(b: TextView, focused: Boolean) {
        // Minimal glass pill: subtle dark when idle, clean accent fill on focus,
        // gentle scale — reads premium on a TV instead of chunky.
        b.background = android.graphics.drawable.GradientDrawable().apply {
            cornerRadius = 100f * resources.displayMetrics.density // fully rounded ends
            setColor(if (focused) accent else UNFOCUSED_PILL)
        }
        b.alpha = if (focused) 1f else 0.92f
        val scale = if (focused) 1.07f else 1f
        b.animate().scaleX(scale).scaleY(scale).setDuration(140).start()
    }

    // ── Controls visibility ──────────────────────────────────────────────────
    private fun showControls() {
        if (menuOpen) return // never draw the transport controls over an open menu
        controls.visibility = View.VISIBLE
        controlsVisible = true
    }

    private fun hideControls() {
        if (rowFocused) return // never yank the row out from under the user
        controls.visibility = View.GONE
        controlsVisible = false
    }

    /** Show controls and (re)arm the auto-hide — but only while actually playing
     *  and not navigating the button row, so a paused player keeps its controls
     *  (and the pause glyph) on screen. */
    private fun bumpControls() {
        if (menuOpen) return
        showControls()
        handler.removeCallbacks(hideRunnable)
        if (!rowFocused && player?.isPlaying == true) handler.postDelayed(hideRunnable, AUTO_HIDE_MS)
    }

    private fun cancelAutoHide() = handler.removeCallbacks(hideRunnable)

    // Some TV remotes/HDMI-CEC send Back as ESCAPE (or another code) instead of
    // KEYCODE_BACK — the OLD Flutter player handled goBack AND escape for exactly
    // this reason. Treat all back-like keycodes as Back.
    private fun isBack(kc: Int) =
        kc == KeyEvent.KEYCODE_BACK || kc == KeyEvent.KEYCODE_ESCAPE

    private fun updateProgress() {
        val p = player ?: return
        val dur = if (p.duration > 0) p.duration else 0L
        // While a seek is pending, show the target so the bar/time don't snap back
        // to the old position between presses and the commit.
        val pos = if (seekTarget >= 0) seekTarget else p.currentPosition.coerceAtLeast(0)
        timeBar.setDuration(dur)
        timeBar.setPosition(pos)
        timeBar.setBufferedPosition(p.bufferedPosition.coerceAtLeast(0))
        positionText.text = fmt(pos)
        durationText.text = fmt(dur)
    }

    private fun updatePlayPauseIcon() {
        val playing = player?.isPlaying == true
        if (playing) {
            if (centerIcon.visibility == View.VISIBLE) {
                centerIcon.animate().alpha(0f).scaleX(0.6f).scaleY(0.6f).setDuration(160)
                    .withEndAction { centerIcon.visibility = View.GONE }.start()
            }
        } else if (centerIcon.visibility != View.VISIBLE) {
            centerIcon.visibility = View.VISIBLE
            centerIcon.alpha = 0f
            centerIcon.scaleX = 0.6f
            centerIcon.scaleY = 0.6f
            centerIcon.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(220)
                .setInterpolator(android.view.animation.OvershootInterpolator(2f)).start()
        }
    }

    // ── Playback actions ─────────────────────────────────────────────────────
    private fun togglePlayPause() {
        val p = player ?: return
        if (p.isPlaying) p.pause() else p.play()
        bumpControls()
    }

    /** Accelerating step: single taps jump 10s; holding ◀▶ ramps to 30s then 60s
     *  so you can scrub across a long video quickly (repeatCount rises while held). */
    private fun seekStep(repeat: Int): Long = when {
        repeat < 3 -> 10_000L
        repeat < 10 -> 30_000L
        else -> 60_000L
    }

    private fun seekBy(deltaMs: Long) {
        val p = player ?: return
        val dur = if (p.duration > 0) p.duration else Long.MAX_VALUE
        val base = if (seekTarget >= 0) seekTarget else p.currentPosition
        seekTarget = (base + deltaMs).coerceIn(0, dur)
        // Jump the bar + times to the target immediately (updateProgress keeps
        // showing seekTarget until the debounced seek commits), so it feels live.
        updateProgress()
        seekIndicator.text = fmt(seekTarget)
        seekIndicator.visibility = View.VISIBLE
        handler.removeCallbacks(hideSeekIndicator)
        handler.postDelayed(hideSeekIndicator, 900)
        handler.removeCallbacks(commitSeek)
        handler.postDelayed(commitSeek, 260)
        bumpControls()
    }

    private fun engageSpeed() {
        val p = player ?: return
        speedEngaged = true
        p.playbackParameters = PlaybackParameters(2f)
        speedBadge.visibility = View.VISIBLE
        cancelAutoHide()
        showControls()
    }

    private fun disengageSpeed() {
        speedEngaged = false
        player?.playbackParameters = PlaybackParameters(speed) // back to the chosen speed
        speedBadge.visibility = View.GONE
        bumpControls()
    }

    // ── Button-row focus (zone 1 = top-right actions, zone 2 = bottom) ────────
    private fun enterZone(zone: Int) {
        showControls()
        focusZone = zone
        cancelAutoHide()
        (if (zone == 1) btnQuality else btnEpisodes).requestFocus()
    }

    private fun exitRow() {
        focusZone = 0
        root.requestFocus()
        bumpControls()
    }

    // ── Key handling ─────────────────────────────────────────────────────────
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Options menu open → native focus drives the D-pad. Back closes the menu
        // RIGHT HERE (consuming it).
        if (menuOpen) {
            if (isBack(event.keyCode)) {
                if (event.action == KeyEvent.ACTION_UP) handleBack()
                return true
            }
            return super.dispatchKeyEvent(event)
        }
        // Skip pill focused: OK jumps past the interval; anything else leaves it
        // and is handled normally (so seeking/controls still work).
        if (skipButton.isFocused) {
            val a = event.action
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.KEYCODE_BUTTON_A ->
                    return super.dispatchKeyEvent(event) // OK performs the skip
                KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_ESCAPE -> {
                    if (a == KeyEvent.ACTION_UP) root.requestFocus()
                    return true
                }
                // Navigate OFF the pill (no focus-stealing): ▼ → button row,
                // ▲ → video, ◀ ▶ → seek. The pill stays reachable via ▼/▲ below.
                KeyEvent.KEYCODE_DPAD_DOWN -> { if (a == KeyEvent.ACTION_DOWN) enterZone(2); return true }
                KeyEvent.KEYCODE_DPAD_UP -> { if (a == KeyEvent.ACTION_DOWN) { focusZone = 0; root.requestFocus(); bumpControls() }; return true }
                KeyEvent.KEYCODE_DPAD_LEFT -> { if (a == KeyEvent.ACTION_DOWN) { focusZone = 0; root.requestFocus(); seekBy(-seekStep(event.repeatCount)) }; return true }
                KeyEvent.KEYCODE_DPAD_RIGHT -> { if (a == KeyEvent.ACTION_DOWN) { focusZone = 0; root.requestFocus(); seekBy(seekStep(event.repeatCount)) }; return true }
                else -> if (a == KeyEvent.ACTION_DOWN) root.requestFocus()
            }
        }
        val down = event.action == KeyEvent.ACTION_DOWN
        when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER,
            KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_NUMPAD_ENTER,
            KeyEvent.KEYCODE_BUTTON_A -> {
                if (rowFocused) return super.dispatchKeyEvent(event) // let the button fire
                if (down) {
                    if (event.repeatCount == 0) {
                        bumpControls()
                        handler.postDelayed(engage2x, HOLD_MS) // hold → 2×
                    }
                    return true
                }
                // ACTION_UP
                handler.removeCallbacks(engage2x)
                if (speedEngaged) disengageSpeed() else togglePlayPause()
                return true
            }

            KeyEvent.KEYCODE_DPAD_LEFT ->
                if (!rowFocused) { if (down) seekBy(-seekStep(event.repeatCount)); return true }

            KeyEvent.KEYCODE_DPAD_RIGHT ->
                if (!rowFocused) { if (down) seekBy(seekStep(event.repeatCount)); return true }

            // ▼ : video → Skip pill (if up) else bottom row · top row → video.
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                if (down) when (focusZone) {
                    0 -> if (skipButton.visibility == View.VISIBLE) skipButton.requestFocus() else enterZone(2)
                    1 -> exitRow()
                }
                return true
            }
            // ▲ : video → top row · bottom row → Skip pill (if up) else video.
            KeyEvent.KEYCODE_DPAD_UP -> {
                if (down) when (focusZone) {
                    0 -> enterZone(1)
                    2 -> if (skipButton.visibility == View.VISIBLE) { focusZone = 0; skipButton.requestFocus() } else exitRow()
                }
                return true
            }

            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ->
                { if (down) togglePlayPause(); return true }
            KeyEvent.KEYCODE_MEDIA_PLAY -> { if (down) { player?.play(); bumpControls() }; return true }
            KeyEvent.KEYCODE_MEDIA_PAUSE -> { if (down) { player?.pause(); bumpControls() }; return true }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { if (down) seekBy(SEEK_MS); return true }
            KeyEvent.KEYCODE_MEDIA_REWIND -> { if (down) seekBy(-SEEK_MS); return true }

            // Back: handled HERE (the path proven on the tester's TV), consumed so
            // the framework never exits on its own. One press hides the controls —
            // whatever button is focused — by reading the ACTUAL view visibility;
            // with nothing on screen it exits.
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_ESCAPE -> {
                if (event.action == KeyEvent.ACTION_UP) handleBack()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /** Flat k,v,k,v String[] → header map (same encoding MainActivity uses). */
    private fun headersFromIntent(): Map<String, String>? {
        val flat = intent.getStringArrayExtra(EXTRA_HEADERS) ?: return null
        if (flat.size < 2) return null
        val map = HashMap<String, String>()
        var i = 0
        while (i + 1 < flat.size) { map[flat[i]] = flat[i + 1]; i += 2 }
        return map.ifEmpty { null }
    }

    private fun subtitleConfigs(): List<MediaItem.SubtitleConfiguration>? {
        val urls = intent.getStringArrayExtra(EXTRA_SUB_URLS) ?: return null
        val langs = intent.getStringArrayExtra(EXTRA_SUB_LANGS)
        val labels = intent.getStringArrayExtra(EXTRA_SUB_LABELS)
        if (urls.isEmpty()) return null
        return urls.mapIndexed { i, u ->
            MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(u))
                .setMimeType(if (u.lowercase().contains(".srt")) MimeTypes.APPLICATION_SUBRIP else MimeTypes.TEXT_VTT)
                .setLanguage(langs?.getOrNull(i))
                .setLabel(labels?.getOrNull(i))
                .build()
        }
    }

    /**
     * OFF (default) → plain DefaultRenderersFactory (hardware only), identical to
     * before. ON → NextRenderersFactory, which adds the hardware MediaCodec
     * renderers first (via super) and appends FFmpeg audio/video only as a
     * fallback. EXTENSION_RENDERER_MODE_ON keeps hardware preferred, so H.264/HEVC
     * video + AAC audio are untouched — FFmpeg only decodes tracks the TV can't
     * (Dolby AC3/E-AC3, DTS → were silent). Opt-in because software decoding can
     * be unstable on some TVs (CloudStream disables it on TV by default too).
     */
    private fun renderersFactory(): RenderersFactory =
        if (intent.getBooleanExtra(EXTRA_SW_DECODE, false)) {
            NextRenderersFactory(this)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
                .setEnableDecoderFallback(true)
        } else {
            DefaultRenderersFactory(this)
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

    /** Hand the final position back so Flutter saves resume + Continue Watching. */
    private fun reportAndFinish() {
        if (!reported) {
            reported = true
            val p = player
            val data = Intent()
                .putExtra(RESULT_POSITION, p?.currentPosition ?: 0L)
                .putExtra(RESULT_DURATION, (p?.duration ?: 0L).coerceAtLeast(0L))
                .putExtra(RESULT_EP_INDEX, currentIndex)
            setResult(RESULT_OK, data)
        }
        finish()
    }

    // Single source of truth for Back. The framework routes every Back press
    // here, so ALL of it is handled here — dispatchKeyEvent no longer intercepts
    // Back (its ACTION_UP gate lost the race to this callback on the tester's TV,
    // so Back exited even with a menu/controls open). Dismiss in priority order;
    // only the bare player (nothing on screen) actually exits.
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Legacy (< API 33) path; on Android 13+ the predictive-back callback runs
        // instead. Both funnel into handleBack().
        handleBack()
    }

    // Single Back hierarchy — shared by the predictive-back callback (API 33+),
    // onBackPressed (legacy), and the Back-key path. One invocation = one step:
    // close an open menu, else hide the controls, else exit the player.
    private fun handleBack() {
        when {
            menuPanel.visibility == View.VISIBLE -> closeMenu()
            controls.visibility == View.VISIBLE -> {
                cancelAutoHide()
                focusZone = 0
                root.requestFocus()
                controls.visibility = View.GONE
                controlsVisible = false
            }
            else -> reportAndFinish()
        }
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations && !isFinishing) reportAndFinish()
        player?.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacksAndMessages(null)
        try { loudness?.release() } catch (_: Exception) {}
        loudness = null
        player?.release()
        player = null
    }
}
