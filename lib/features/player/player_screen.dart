import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart' show Track;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:floating/floating.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/di/injector.dart';
import '../../core/repository/source_repository.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/playback/external_player.dart';
import '../../core/playback/playback_prefs.dart';
import 'subtitle_style.dart';
import 'subtitle_font_service.dart';
import '../../core/torrent/torrent_util.dart';
import '../../core/models/episode.dart';
import '../../core/models/episode_title.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/playback/subtitle_search_service.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/brand_loader.dart';
import '../../core/ui/frosted_surface.dart';
import '../../core/ui/subtitle_language_picker.dart';
import '../detail/cubit/detail_cubit.dart' show seasonOf, seasonsOf;
import '../../core/cast/cast_controller.dart';
import '../../core/cast/cast_proxy.dart';
import '../watch_together/watch_together_controller.dart';
import '../watch_together/ui/room_panel.dart';
import '../../core/app_mode.dart';
import '../../core/tv/tv_focusable.dart';
import '../settings/settings_screen.dart';
import 'player_controller.dart';
import 'player_controls_config.dart';
import 'player_tv_controls.dart';
import 'seek_preview.dart';
import 'color_profiles.dart';
import 'shader_presets.dart';
import 'drm_player_screen.dart';

part 'player_cast_panel.dart';
part 'player_overlays.dart';
part 'player_controls_overlay.dart';
part 'player_seek_bar.dart';
part 'player_controls_widgets.dart';
part 'player_episodes_panel.dart';
part 'player_sheets.dart';

/// Netflix-style fullscreen player: a live [Video] with a tap-to-toggle
/// overlay (auto-hiding), configurable double-tap seek, long-press 2x speed, a
/// stream-bound seek slider, and Speed / Audio / Quality / Source / Next
/// controls. Forces landscape + immersive UI while open and restores portrait
/// on dispose.
/// External players that forward HTTP request headers (Referer/Origin/Cookie)
/// to the stream. Players NOT on this list (VLC, SPlayer, LeePlayer, …) ignore
/// them, so a header-gated source 403s — for those, `_launchExternalThenPop`
/// hands the player the local header-injecting proxy URL instead (which adds
/// the headers upstream). Prefix-matched to cover package variants (e.g. MX
/// Player free `.ad` + `.pro`).
const List<String> kHeaderForwardingPlayers = [
  'com.mxtech.videoplayer', // MX Player (free .ad + pro)
  'com.brouken.player',     // Just Player
];

/// True when [headers] carry a gating header (Referer/Origin/Cookie) that the
/// chosen external player [pkg] cannot forward — so the stream would 403 and we
/// should use the built-in player instead. Pure so it is unit-testable.
@visibleForTesting
bool headerGatedButPlayerCant(Map<String, String>? headers, String pkg) {
  if (headers == null || headers.isEmpty || pkg.isEmpty) return false;
  final gated = headers.keys.any((k) {
    final lk = k.toLowerCase();
    return lk == 'referer' || lk == 'origin' || lk == 'cookie';
  });
  if (!gated) return false;
  return !kHeaderForwardingPlayers.any(pkg.startsWith);
}

/// True when [url] is already served by a local proxy (localhost / 127.0.0.1) —
/// e.g. a CloudStream extractor's own proxy.
///
/// No longer gates the external-player hand-off. It used to: such URLs were
/// passed through untouched because they were assumed to be header-injected
/// already. They aren't — an extractor's proxy forwards whatever UA called it,
/// so VLC's UA reached Cloudflare and drew a 403. They now go through our proxy
/// like any other header-gated source.
@visibleForTesting
bool isLocalStreamUrl(String url) {
  final u = url.toLowerCase();
  return u.startsWith('http://localhost') ||
      u.startsWith('http://127.0.0.1') ||
      u.startsWith('https://localhost') ||
      u.startsWith('https://127.0.0.1');
}

/// True when [url] is an MPEG-DASH manifest (`.mpd`, ignoring any query string).
/// External players can't reliably play header-gated DASH and our proxy only
/// rewrites HLS, so these route to the built-in player.
@visibleForTesting
bool isDashUrl(String url) => url.toLowerCase().split('?').first.endsWith('.mpd');

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.sourceId,
    required this.resume,
    required this.resolveSources,
    this.pollSources,
    this.episodes = const [],
    this.startIndex = 0,
    this.episodesResolver,
    this.resumeEpisodeId,
    this.resumeEpisodeNumber,
    this.resumePosition = Duration.zero,
    this.history,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.showUrl,
    this.category,
    this.malId,
    this.scrobbleTitle,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
    this.availableCategories = const [],
    this.joinRoomCode,
    this.playerOverride,
    this.initialSource,
  });

  /// A mirror picked from the episode list's long-press menu, opened instead
  /// of the adaptive default. One-shot: the cubit clears it after the first
  /// episode so nothing later is affected.
  final VideoSource? initialSource;

  /// Set by the episode list's long-press sheet: play this one episode here,
  /// ignoring the Settings default. Empty string means the built-in player
  /// even when an external one is configured. Null keeps today's behaviour of
  /// reading [PlaybackPrefs.externalPlayerPackage].
  final String? playerOverride;

  final String sourceId;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;

  /// Optional reader for links that finish resolving AFTER [resolveSources]
  /// returned. That call comes back on the first usable link so playback starts
  /// quickly, while the rest keep resolving natively instead of being cancelled;
  /// this is how the Sources sheet ends up complete without anything having
  /// waited. Null keeps the previous behaviour exactly.
  final Future<({List<VideoSource> sources, bool done})> Function(
    String episodeUrl,
  )?
  pollSources;

  /// Either pass [episodes] directly, or an [episodesResolver] that the player
  /// awaits behind its branded loader (so navigation is instant — no blocking
  /// spinner before pushing). [resumeEpisodeId] picks the start index once
  /// resolved.
  final List<Episode> episodes;
  final int startIndex;
  final Future<List<Episode>> Function()? episodesResolver;
  final String? resumeEpisodeId;

  /// Episode number of the entry being resumed, used to re-find the episode
  /// when [resumeEpisodeId] no longer matches (a provider regenerated the
  /// opaque episode id between sessions).
  final double? resumeEpisodeNumber;

  /// Position the Continue Watching entry recorded — a reliable fallback when
  /// the per-episode ResumeStore key no longer matches. Zero (the default) for
  /// fresh plays, which fall back to the normal ResumeStore lookup.
  final Duration resumePosition;

  // Optional show-context threaded into history (Continue Watching feed).
  final WatchHistory? history;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String? showUrl;
  final String? category;

  /// MyAnimeList id (anime) for AniList auto-scrobble. Null = no scrobbling.
  final int? malId;

  /// Anime title used to resolve the AniList entry when [malId] is absent.
  /// Non-null only for anime.
  final String? scrobbleTitle;

  /// TMDB id (movies/series) for Simkl tracking; [tmdbIsTv] selects namespace.
  final int? tmdbId;
  final bool tmdbIsTv;

  /// IMDb id (movies/series) for Simkl tracking when no TMDB id is exposed.
  final String? imdbId;

  /// Sub/Dub categories this title offers. When length <= 1 the player hides
  /// the Version (Sub/Dub) section. Switching re-resolves the current episode
  /// in the chosen language (see [PlayerCubit.switchCategory]).
  final List<String> availableCategories;

  /// When non-null the player auto-joins this Watch Together room code after
  /// the session is wired. Used by the Join-from-anywhere flow in the sheet.
  final String? joinRoomCode;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// Which player this screen should hand off to: the episode list's one-off
  /// pick when there is one, otherwise the standing Settings default.
  ///
  /// Resolved in a single place because three separate branches consult it —
  /// the initState hand-off, the header-gated proxy path, and the launch call.
  /// Reading prefs directly in each is how an override gets honoured by two of
  /// them and silently dropped by the third.
  String get _chosenPlayer =>
      widget.playerOverride ?? sl<PlaybackPrefs>().externalPlayerPackage;

  late final PlayerCubit _c;
  final WatchTogetherController _room = sl<WatchTogetherController>();

  // Stored so we can remove it in dispose() — the singleton outlives this screen.
  late final VoidCallback _roomListener;
  bool _attached = false; // true only after _wireRoom() runs

  // Position sampled down to whole seconds. The always-mounted Skip / Next-episode
  // pills only care about second-granularity, but the raw position stream fires
  // ~once per decoded frame — so a StreamBuilder on it rebuilt (and forced a
  // Flutter frame) every ~1/60s the whole time the video played, pinning the
  // panel at 60 even for 24fps video. Sampling to seconds lets Flutter fall back
  // to redrawing only when the video texture actually updates. Broadcast (mpv's
  // position stream is), so both pills can share this one subscription.
  late final Stream<Duration> _positionBySecond = _c.player.stream.position
      .map((p) => Duration(seconds: p.inSeconds))
      .distinct();

  bool _controlsVisible = true;
  bool _holding = false; // long-press 2x active
  Timer? _hideTimer;

  // Double-tap seek indicator (accumulates on rapid taps, shows a running total).
  Timer? _seekLabelTimer;
  int _seekAccum = 0; // accumulated seconds in the current burst
  int _seekSide = 0; // -1 = left/rewind, +1 = right/forward, 0 = hidden
  int _seekTick = 0; // bumps each tap → re-keys the indicator so it replays
  // The real seek is debounced: rapid taps bump the indicator instantly but the
  // player only jumps once, after tapping stops — one smooth jump instead of a
  // buffer-stutter per tap. Signed pending seconds, not yet applied.
  Timer? _seekDebounceTimer;
  int _pendingSeek = 0;

  // Tap-zone burst tracking. The side zones used to hand double-tap-seek to
  // GestureDetector.onDoubleTapDown, but that recognizer holds the gesture
  // arena for kDoubleTapTimeout (300ms) on every FIRST tap — so a plain tap on
  // the left/right third sat there for 300ms before the controls showed or hid,
  // while the centre third (tap-only) and the locked screen resolved on lift.
  // A tap that looks ignored gets retried, and the retry landed inside that
  // window and became a seek, so the controls never toggled at all. Spotting
  // the double tap here instead keeps the arena free — see [_tapZone] for how
  // hide and show are split so a seek never flashes the bars.
  static const Duration _tapBurstWindow = Duration(milliseconds: 280);
  DateTime? _lastZoneTapAt;
  int _lastZoneTapSide = 0; // -1 = left, 0 = centre, +1 = right
  int _zoneTapCount = 0; // taps so far in the current burst
  Timer? _showTimer; // queued reveal, dropped if the tap turns into a seek

  // ── Pinch-to-zoom (continuous, CloudStream-style: 1×–4×, pan + snap-back) ──
  // Driven by a passive Listener watching raw pointers (NOT a scale recognizer),
  // so the existing 1-finger brightness/volume/scrub gestures stay untouched —
  // a 2-finger pinch just sets _pinching, which those handlers bail on.
  double _zoom = 1.0; // current video zoom (1.0 = fit-to-screen)
  Offset _zoomPan = Offset.zero; // pan offset while zoomed in
  int _zoomIndex = -1; // episode this zoom belongs to (reset on episode change)
  bool _pinching = false; // 2 fingers down → suppress the 1-finger swipes
  final Map<int, Offset> _pointers = {}; // live pointers tracked for the pinch
  double _pinchBaseDist = 0; // finger spread when the pinch started
  double _pinchBaseZoom = 1.0;
  Offset _pinchBaseFocal = Offset.zero;
  Offset _pinchBasePan = Offset.zero;

  // Duration tracked off the stream so the slider has a max even before
  // a position event arrives.
  Duration _duration = Duration.zero;

  // User's preferred double-tap seek step (±5/10/15/30s), read once at session
  // start. Backed by PlaybackPrefs.doubleTapSeconds.
  final int _seekSeconds = sl<PlaybackPrefs>().doubleTapSeconds;

  // ── Brightness / volume swipe gestures ──────────────────────────────────
  final bool _gesturesEnabled = sl<PlaybackPrefs>().gestureControls;
  // Horizontal drag-to-seek. Its own switch, not part of [_gesturesEnabled],
  // which only ever meant the vertical brightness/volume swipes.
  final bool _swipeSeekEnabled = sl<PlaybackPrefs>().swipeSeek;
  final bool _holdSpeedEnabled = sl<PlaybackPrefs>().holdSpeed;
  final bool _skipIntroEnabled = sl<PlaybackPrefs>().skipIntro;
  // Fields for the in-player info overlay (read once). Shown on demand via the
  // ⓘ button in the top bar, NOT auto with the controls.
  final List<String> _infoFields = sl<PlaybackPrefs>().playerInfoFields;
  bool _infoPanelOpen = false;
  bool _flashing = false; // brief white flash on screenshot capture
  // Always-on plain-text quality label (top-right), independent of the ⓘ panel.
  final bool _alwaysShowQuality = sl<PlaybackPrefs>().alwaysShowQuality;
  // MegaSkip — manual jump-forward button (Aniyomi-style). Read once at open
  // (the player is recreated per session, like the other prefs above).
  final bool _megaSkipEnabled = sl<PlaybackPrefs>().megaSkip;
  final int _megaSkipSeconds = sl<PlaybackPrefs>().megaSkipSeconds;
  bool _megaFlash = false; // brief "+Ns" flash shown right after a MegaSkip tap
  Timer? _megaFlashTimer;
  bool _dragIsBrightness = false; // left half = brightness, right half = volume
  double _dragValue = 0; // running 0..1 value during a vertical drag
  int _lastHudPct = -1; // last HUD %, to haptic-tick when crossing a landmark
  // HUD shown while adjusting (Netflix-style brightness/volume indicator).
  bool _hudVisible = false;
  double _hudValue = 0;
  bool _hudIsBrightness = false;
  Timer? _hudTimer;

  // ── Lock / zoom / drag-seek / up-next ─────────────────────────────────────
  bool _locked = false; // controls + gestures disabled
  // Aspect cycle: Fit (contain) → Fill (cover) → Stretch (fill).
  static const List<(BoxFit, String)> _fits = [
    (BoxFit.contain, 'Fit'),
    (BoxFit.cover, 'Fill'),
    (BoxFit.fill, 'Stretch'),
  ];
  int _fitIndex = 0;
  // Horizontal drag-to-seek.
  bool _hSeeking = false;
  Duration _hSeekStart = Duration.zero;
  Duration _hSeekTarget = Duration.zero;
  // "Up next" auto-advance card.
  Timer? _upNextTimer;
  int _upNextLeft = 0;
  bool _upNext = false;

  // Sleep timer.
  Timer? _sleepTimer;
  bool _sleepActive = false; // a timer or end-of-episode stop is armed
  bool _sleepEndOfEpisode = false;
  bool _sleepCloseApp = false; // when it fires, exit the app (not just pause)

  bool _chatOpen = false; // in-room chat panel visible

  // ── Chromecast ────────────────────────────────────────────────────────────
  CastState _prevCastState = CastState.unavailable;

  // TV bar visibility — only used when [AppMode.isTv] is true.
  // Stored here so [PopScope] can gate it at the Scaffold level.
  bool _tvBarVisible = true;

  bool _ready = false; // the player session (cubit) is built
  // Set when a Watch Together join can't resolve the room's source on this
  // device — show a clear message instead of silently bouncing to a portrait
  // home screen.
  String? _loadError;

  // Picture-in-Picture (Android only; iOS has no PiP path with media_kit).
  // `floating` powers the manual button + the status poll; auto-PiP-on-leave is
  // done natively (MainActivity) because the plugin's OnLeavePiP only works on
  // Android 12+ and silently no-ops on older devices.
  final Floating _floating = Floating();
  static const MethodChannel _pipChannel = MethodChannel('zangetsu/pip');
  bool _pipSupported = false; // device supports PiP + we're on Android
  bool _inPip = false; // currently rendering inside the PiP window
  StreamSubscription<PiPStatus>? _pipSub;
  // Playing / video-size listeners that keep the PiP window's buttons and
  // aspect ratio current. PiP-only — they don't feed anything else.
  final List<StreamSubscription<dynamic>> _pipStateSubs = [];

  @override
  void initState() {
    super.initState();
    // Refresh the "enhancement shaders downloaded?" flag so the in-player picker
    // gates correctly (they're fetched on demand from Settings). Fire-and-forget.
    unawaited(ShaderPresets.refreshDownloaded());
    // Default external player: hand the stream off to the chosen app and close
    // this screen instead of starting the in-app player. Falls back to in-app
    // if the launch can't be set up, so playback never silently dies.
    if (Platform.isAndroid &&
        _chosenPlayer.isNotEmpty) {
      _launchExternalThenPop();
      return;
    }
    _initInApp();
  }

  /// Watching upright (the ⟳ button). Starts false — every episode opens
  /// landscape, as it always has.
  bool _portraitMode = false;

  /// The orientation this player holds right now. Single source of truth: the
  /// screen pins orientation in more than one place (open, and either side of
  /// the Settings trip), and hardcoding landscape at each of them is what would
  /// throw you back to landscape after a detour.
  List<DeviceOrientation> get _orientationLock => _portraitMode
      ? const [DeviceOrientation.portraitUp]
      : const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];

  /// Locked either way rather than following the sensor: a phone resting flat
  /// shouldn't flip the video mid-episode, and this still works for people who
  /// keep system auto-rotate switched off.
  void _toggleOrientation() {
    setState(() => _portraitMode = !_portraitMode);
    SystemChrome.setPreferredOrientations(_orientationLock);
    _bumpControls();
  }

  void _initInApp() {
    SystemChrome.setPreferredOrientations(_orientationLock);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Wake-lock is bound to playback in _startSession, once the player exists.
    // The volume swipe sets the real system volume; hide the OS volume bar so
    // only our own HUD shows (CloudStream draws its own too). Restored on exit.
    if (_gesturesEnabled) {
      FlutterVolumeController.updateShowSystemUI(false);
    }
    _setupPip();
    // Cast state listener — wired here so it is active even before the episode
    // list resolves. The callbacks are guarded on _ready (session built) and on
    // state.active != null, so they are always safe to call.
    _prevCastState = sl<CastController>().state;
    sl<CastController>().removeListener(_onCastStateChanged); // idempotent
    sl<CastController>().addListener(_onCastStateChanged);
    if (widget.episodesResolver != null && widget.episodes.isEmpty) {
      _resolveThenStart(); // instant nav: resolve behind the branded loader
    } else {
      _startSession(widget.episodes, widget.startIndex);
    }
  }

  // Enable the wake-lock while playing/buffering, release it on pause. Only
  // toggles on an actual change so it never spams the platform channel, and
  // respects the keepScreenOn pref (off → never held).
  void _syncWakelock() {
    final want = sl<PlaybackPrefs>().keepScreenOn &&
        (_c.player.state.playing || _c.player.state.buffering);
    if (want == _wakelockOn) return;
    _wakelockOn = want;
    if (want) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  // ── Chromecast handoff / disconnect-resume ────────────────────────────────

  void _onCastStateChanged() {
    if (!mounted) return;
    final castCtrl = sl<CastController>();
    final newState = castCtrl.state;
    final prev = _prevCastState;
    _prevCastState = newState;

    if (!_ready) return; // session not built yet; nothing to pause/resume

    // --- Handoff: local → cast ---
    if (newState == CastState.connected && prev != CastState.connected) {
      final active = _c.state.active;
      if (active == null) return;
      if (_c.player.state.playing) _c.player.pause(); // pause local mpv first
      _castHandoff(active); // async: start proxy → load onto the receiver
      if (mounted) setState(() {}); // show the "Casting to <TV>" panel
      return;
    }

    // --- Disconnect-resume: cast → local ---
    if (prev == CastState.connected && newState != CastState.connected) {
      sl<CastProxyServer>().stop(); // tear down the LAN proxy
      final resumePos = castCtrl.position;
      if (resumePos > Duration.zero) _c.seekTo(resumePos);
      _c.player.play();
      if (mounted) setState(() {}); // restore the normal player UI
    }
  }

  /// Route the current stream through the on-device proxy so the Chromecast
  /// can fetch header-locked HLS (Referer / UA / cookies the Cast receiver
  /// can't send itself), then load it onto the receiver at the current
  /// position. Falls back to the direct URL when no LAN proxy is available —
  /// casting then works only for un-protected streams.
  Future<void> _castHandoff(VideoSource active) async {
    final castCtrl = sl<CastController>();
    final proxy = sl<CastProxyServer>();
    final startAt = _c.currentPosition;
    // The proxy URL carries no extension, so send the real mime explicitly.
    final mime = castMimeFor(active.container, active.url);

    var url = active.url;
    var subs = active.subtitles;
    try {
      final proxied = await proxy.serve(active.url, active.headers);
      if (proxied != null) {
        url = proxied;
        // Header-locked subtitle tracks need proxying too.
        subs = [
          for (final s in active.subtitles)
            Subtitle(
              url: proxy.proxify(s.url) ?? s.url,
              lang: s.lang,
              label: s.label,
              format: s.format,
              isDefault: s.isDefault,
            ),
        ];
      }
    } catch (_) {
      // Proxy failed to start — fall through with the direct URL.
    }
    if (!mounted) return;
    castCtrl.loadCurrent(
      url: url,
      container: active.container,
      mime: mime,
      // Headers are injected by the proxy now (the native side ignores them).
      title: widget.showTitle,
      poster: widget.cover,
      subtitles: subs,
      startAt: startAt,
    );
  }

  // ── Picture-in-Picture ────────────────────────────────────────────────────

  /// Detect PiP support (Android only), then arm auto-PiP on app-leave and
  /// track the PiP status so the UI can collapse to video-only inside the
  /// floating window. Best-effort — any failure just leaves PiP disabled.
  Future<void> _setupPip() async {
    if (!Platform.isAndroid) return;
    try {
      final available = await _floating.isPipAvailable;
      if (!mounted || !available) return;
      setState(() => _pipSupported = true);
      _pipSub = _floating.pipStatusStream.listen((status) {
        if (!mounted) return;
        final inPip = status == PiPStatus.enabled;
        if (inPip != _inPip) setState(() => _inPip = inPip);
        // Re-push on entry. The stream listeners below only fire on CHANGE,
        // and playback usually starts before this async setup finishes — so
        // the playing stream has already emitted and won't again, leaving the
        // window's icon stuck at whatever the first read happened to catch.
        // This is the one moment the icon is definitely about to be seen.
        if (inPip) _pushPipState();
      });
      // Arm auto-PiP-on-leave natively (works on Android 8.0+, unlike the
      // plugin's OnLeavePiP which needs 12+) — gated by the Playback setting.
      // The manual PiP button is unaffected by this toggle.
      await _pipChannel.invokeMethod('setAutoPip', sl<PlaybackPrefs>().autoPip);

      // The PiP window's own buttons come back up this channel. They call the
      // same controller methods the on-screen transport does — no separate
      // playback path, nothing here changes how the player itself behaves.
      _pipChannel.setMethodCallHandler((call) async {
        if (!mounted) return null;
        switch (call.method) {
          case 'play_pause':
            _c.togglePlay();
          case 'rewind':
            _c.seekBy(const Duration(seconds: -10));
          case 'forward':
            _c.seekBy(const Duration(seconds: 10));
        }
        return null;
      });

      _pushPipState();
      _pipStateSubs.addAll([
        _c.player.stream.playing.listen((_) => _pushPipState()),
        // Fires on the first decoded frame and on every source/quality switch,
        // so the window re-sizes when the video actually changes shape.
        _c.player.stream.height.listen((_) => _pushPipState()),
      ]);
    } catch (_) {
      /* PiP just stays off */
    }
  }

  /// Hand the PiP window the current playback state and video size.
  ///
  /// Android bakes the play/pause icon into the window's action list, so there
  /// is no way to update a single button — the whole set has to be rebuilt and
  /// re-sent. The size rides along on the same call, which is what lets the
  /// window match the real aspect instead of assuming 16:9.
  void _pushPipState() {
    if (!mounted || !_pipSupported || !_ready) return;
    _pipChannel
        .invokeMethod('setState', {
          'playing': _c.player.state.playing,
          'width': _c.player.state.width ?? 0,
          'height': _c.player.state.height ?? 0,
        })
        .catchError((_) => null);
  }

  /// Enter PiP immediately (the player's PiP button).
  Future<void> _enterPip() async {
    if (!_pipSupported) return;
    try {
      await _floating.enable(
        const ImmediatePiP(aspectRatio: Rational.landscape()),
      );
    } catch (_) {}
  }

  /// Resolve the start episode + its best source and open it in the user's
  /// chosen external player, then pop. The branded loader shows briefly while
  /// resolving. Any failure falls back to the in-app player.
  Future<void> _launchExternalThenPop() async {
    try {
      var eps = widget.episodes;
      if (eps.isEmpty && widget.episodesResolver != null) {
        eps = await widget.episodesResolver!();
      }
      if (eps.isEmpty) throw StateError('no episodes');
      var idx = widget.startIndex;
      if (widget.resumeEpisodeId != null) {
        var i = eps.indexWhere((e) => e.id == widget.resumeEpisodeId);
        if (i < 0 && widget.resumeEpisodeNumber != null) {
          i = eps.indexWhere((e) => e.number == widget.resumeEpisodeNumber);
        }
        if (i >= 0) idx = i;
      }
      final ep = eps[idx.clamp(0, eps.length - 1)];
      final sources = await widget.resolveSources(ep.url);
      final prefer = widget.category == 'dub' ? AudioKind.dub : AudioKind.sub;
      final src = pickDefault(sources, prefer: prefer);
      if (src == null) throw StateError('no source');
      // A torrent can't be handed to an external player as a magnet — stream it
      // through our engine via the in-app player instead.
      if (isTorrentUrl(src.url)) {
        _initInApp();
        if (mounted) setState(() {});
        return;
      }
      // Header-gated source + a player that can't forward headers. Two cases:
      //  • DASH (.mpd): our proxy only rewrites HLS and external players can't do
      //    header-gated DASH → play in the built-in player (mpv handles it).
      //  • otherwise (remote HLS, or an extractor's own localhost proxy): hand
      //    the player our localhost proxy URL (no headers — the proxy injects
      //    them upstream).
      // Extractor-local URLs used to be passed through untouched, on the
      // assumption they were already header-injected. They aren't: those proxies
      // forward whatever UA called them, so mpv (source UA) played fine while VLC
      // (VLC/3.0.23) drew a 403 off Cloudflare and the extractor answered 500.
      // Fetching through our proxy puts the source UA back on the wire.
      // MX/Just Player (header-forwarding) and non-header-gated sources never
      // reach this branch — the unchanged direct hand-off below covers them.
      final extPkg = _chosenPlayer;
      var playUrl = src.url;
      var launchHeaders = src.headers ?? const <String, String>{};
      if (headerGatedButPlayerCant(src.headers, extPkg)) {
        if (isDashUrl(src.url)) {
          _initInApp(); // DASH → built-in (external can't do header-gated DASH)
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Using the built-in player for this source.'),
              ),
            );
          }
          return;
        }
        final local = await ExternalPlayer().proxyStreamUrl(src.url, src.headers!);
        if (!mounted) return;
        if (local == null) {
          _initInApp(); // proxy unavailable → built-in (never a black screen)
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This source needs special headers your external player can’t '
                'send — using the built-in player.',
              ),
            ),
          );
          return;
        }
        // Play the proxied URL; headers are injected upstream, so none are
        // needed on the intent (VLC/SPlayer ignore them anyway).
        playUrl = local;
        launchHeaders = const <String, String>{};
      }
      // External players give no progress callback and the in-app scrobbler
      // never runs for them — so scrobble the episode at hand-off (the only
      // reliable signal). Anime-gated + de-duped inside the service.
      final epNum = ep.number;
      if (epNum != null && epNum > 0 && epNum == epNum.truncateToDouble()) {
        sl<TrackerHub>().scrobble(
          malId: widget.malId,
          title: widget.scrobbleTitle,
          tmdbId: widget.tmdbId,
          tmdbIsTv: widget.tmdbIsTv,
          imdbId: widget.imdbId,
          episode: epNum.toInt(),
        );
      }
      final subs = src.subtitles
          .map((s) => {'url': s.url, 'name': s.label ?? s.lang})
          .toList();
      final title = [
        widget.showTitle,
        ep.title,
      ].whereType<String>().where((s) => s.isNotEmpty).join(' • ');
      final res = await ExternalPlayer().launch(
        url: playUrl,
        package: _chosenPlayer,
        title: title.isEmpty ? null : title,
        headers: launchHeaders,
        subtitles: subs,
        positionMs: 0,
      );
      if (!mounted) return;
      // If the player LAUNCHED, trust it — it took the stream. Many players
      // (VLC especially) open the video in their own task and return to us
      // immediately with no progress report, so `played` is NOT a reliable
      // failure signal; using it made the app spuriously fall back to the
      // built-in player (double playback) even while the external player was
      // playing fine. Only a genuine launch failure (not installed / no
      // activity) falls back to the built-in player.
      if (res.launched) {
        _leavePlayer();
      } else {
        _initInApp(); // not installed / no activity → built-in
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        _initInApp();
        setState(() {});
      }
    }
  }

  StreamSubscription<bool>? _completedSub;
  // Wake-lock bound to playback: screen stays on while playing OR buffering and
  // is released on pause, so a paused-and-forgotten player lets the screen time
  // out instead of burning battery at full brightness. Mirrors CloudStream.
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  bool _wakelockOn = false;

  // A DRM (clearkey CENC/DASH) source can't play in mpv, so the controller calls
  // this instead of opening it: open the ExoPlayer-backed [DrmPlayerScreen] (which
  // does clearkey natively) for this episode's sources, then leave this
  // never-played mpv screen. mpv itself is untouched — it just never opens a DRM url.
  bool _drmHandedOff = false;
  Future<void> _handoffToNativeDrm(VideoSource drm) async {
    if (_drmHandedOff) return; // _open can fire more than once (switch/failover)
    _drmHandedOff = true;
    await _c.player.pause(); // don't buffer the idle mpv player behind the DRM one
    if (!mounted) return;
    // push (NOT pushReplacement): keep this mpv screen alive underneath so its
    // dispose() — which resets phones to portrait — doesn't run mid-DRM-playback
    // and flip the DRM player out of landscape. It never opened media, so it's
    // inert. When the DRM screen closes, leave this screen too (back to Home/Detail).
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DrmPlayerScreen(
          sources: _c.state.sources,
          initial: drm,
          title: widget.showTitle,
          subtitle: _episodeLabelOrNull(),
        ),
      ),
    );
    _leavePlayer();
  }

  String? _episodeLabelOrNull() {
    final eps = _c.episodes;
    final i = _c.state.currentIndex;
    if (i < 0 || i >= eps.length) return null;
    final e = eps[i];
    return e.title.isNotEmpty ? e.title : null;
  }

  void _startSession(List<Episode> eps, int startIndex) {
    _c = PlayerCubit(
      sourceId: widget.sourceId,
      episodes: eps,
      resume: widget.resume,
      resolveSources: widget.resolveSources,
      pollSources: widget.pollSources,
      dio: sl<Dio>(),
      history: widget.history,
      showTitle: widget.showTitle,
      cover: widget.cover,
      coverHeaders: widget.coverHeaders,
      showUrl: widget.showUrl,
      category: widget.category,
      malId: widget.malId,
      scrobbleTitle: widget.scrobbleTitle,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      availableCategories: widget.availableCategories,
      initialResume: widget.resumePosition,
      initialSource: widget.initialSource,
      onDrmSource: _handoffToNativeDrm,
    )..init(startIndex);

    // Bind the wake-lock to playback now that the player exists: on while
    // playing/buffering, released on pause. Set up here (not _initInApp) because
    // _c isn't built until this point.
    _playingSub = _c.player.stream.playing.listen((_) => _syncWakelock());
    _bufferingSub = _c.player.stream.buffering.listen((_) => _syncWakelock());
    _syncWakelock();

    _room.attachPlayer(
      localPosition: () => _c.player.state.position,
      onApplyRemote: (playing, pos, rate) =>
          _c.applyRemote(playing: playing, position: pos, rate: rate),
      onEpisodeChange: (r) {
        // Follow the host to their episode within the show we already loaded.
        // Position is then re-synced by the controller's applyRemote tick, so
        // we only need to switch episodes here. Cross-show following is out of
        // scope for v1 — if no episode matches the room state, do nothing.
        var i = _c.episodes.indexWhere((e) => e.id == r.episodeId);
        if (i < 0 && r.episodeNumber != null) {
          i = _c.episodes.indexWhere((e) => e.number == r.episodeNumber);
        }
        if (i >= 0 && i != _c.state.currentIndex) _c.openEpisode(i, fromRoom: true);
      },
      content: {
        'sourceId': _c.sourceId,
        'sourceLabel': widget.showTitle ?? '',
        'showUrl': widget.showUrl ?? '',
        'showTitle': widget.showTitle ?? '',
        'cover': widget.cover ?? '',
        'episodeId': _c.currentEpisode.id,
        'episodeNumber': _c.currentEpisode.number,
        'episodeUrl': _c.currentEpisode.url,
        'category': widget.category ?? 'sub',
        'malId': widget.malId,
        'tmdbId': widget.tmdbId,
        'positionMs': _c.player.state.position.inMilliseconds,
      },
    );
    _wireRoom(_room);
    if (widget.joinRoomCode != null) _room.join(widget.joinRoomCode!);

    // Drive the "Up next" card on episode completion (the controller no longer
    // auto-advances; we show a 5s countdown card instead).
    _completedSub = _c.player.stream.completed.listen((done) {
      if (done) _onEpisodeComplete();
    });
    if (mounted) setState(() => _ready = true);
    _scheduleHide();
  }

  void _wireRoom(WatchTogetherController room) {
    _roomListener = () {
      _c.roomRole = room.role;
      if (mounted) setState(() {});
    };
    room.addListener(_roomListener);
    _attached = true;
    _c.onLocalPlayback = (event, pos) {
      switch (event) {
        case 'play':
          room.broadcastPlay(pos);
          break;
        case 'pause':
          room.broadcastPause(pos);
          break;
        case 'seek':
          room.broadcastSeek(pos);
          break;
        case 'episode':
          final ep = _c.currentEpisode;
          room.broadcastEpisode(
              episodeId: ep.id, number: ep.number, episodeUrl: ep.url);
          break;
      }
    };
  }

  Future<void> _resolveThenStart() async {
    try {
      final eps = await widget.episodesResolver!();
      if (!mounted) return;
      if (eps.isEmpty) {
        _failJoinOrPop();
        return;
      }
      var idx = 0;
      if (widget.resumeEpisodeId != null) {
        var i = eps.indexWhere((e) => e.id == widget.resumeEpisodeId);
        if (i < 0 && widget.resumeEpisodeNumber != null) {
          i = eps.indexWhere((e) => e.number == widget.resumeEpisodeNumber);
        }
        if (i >= 0) idx = i;
      }
      _startSession(eps, idx);
    } catch (_) {
      if (mounted) _failJoinOrPop();
    }
  }

  /// When a Watch Together join can't resolve the room's source on this device
  /// (e.g. it's a CloudStream plugin the joiner hasn't installed), show a clear
  /// message rather than silently bouncing back. A normal launch keeps the pop.
  ///
  /// Two distinct cases:
  ///  - Source NOT installed → guide the user to install it.
  ///  - Source IS installed but episode resolution returned empty/failed →
  ///    transient failure message (provider-side issue, not a missing source).
  void _failJoinOrPop() {
    if (widget.joinRoomCode != null) {
      final sourceInstalled = sl<SourceRepository>().hasSource(widget.sourceId);
      setState(() => _loadError = sourceInstalled
          ? "Couldn't load this show right now.\n\n"
                "The source is available on your device, but the episode list "
                'came back empty. Tap Back and try again.'
          : "Couldn't open this room's video source on your device.\n\n"
                "The host is watching on a source you don't have installed. Add it "
                'from Settings → Add CloudStream repository, or ask the host to use a '
                'built-in source.');
    } else {
      _leavePlayer();
    }
  }

  // Last back press for the "double back to exit" close mode.
  DateTime? _lastBackPress;

  // Imperative "leave the player now". Uses pop() (not maybePop) so it slips
  // past the close-confirmation PopScope — for programmatic exits (external /
  // DRM handoff, load failure) and once the user has confirmed a close.
  void _leavePlayer() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  // A user-initiated close (back button, system back, cast-panel back). Applies
  // the Settings → Playback → Close confirmation choice: 'direct' never reaches
  // here (PopScope lets it pop straight through); 'confirm' asks first;
  // 'double_back' (default) needs a second back within 2s.
  Future<void> _handleCloseRequest() async {
    switch (sl<PlaybackPrefs>().closeConfirmation) {
      case 'confirm':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Close video?'),
            content: const Text('Are you sure you want to close the video?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        if (ok == true) _leavePlayer();
      case 'direct':
        _leavePlayer();
      default: // 'double_back'
        final now = DateTime.now();
        if (_lastBackPress != null &&
            now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
          _leavePlayer();
          return;
        }
        _lastBackPress = now;
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('Press back again to exit'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _showTimer?.cancel();
    _seekLabelTimer?.cancel();
    _seekDebounceTimer?.cancel();
    _hudTimer?.cancel();
    _upNextTimer?.cancel();
    _megaFlashTimer?.cancel();
    _sleepTimer?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _pipSub?.cancel();
    for (final s in _pipStateSubs) {
      s.cancel();
    }
    _pipStateSubs.clear();
    sl<CastController>().removeListener(_onCastStateChanged);
    // Disarm auto-PiP so leaving the closed player can't trigger it, and drop
    // the handler so a stray window button can't reach a dead controller.
    if (_pipSupported) {
      _pipChannel.setMethodCallHandler(null);
      _pipChannel.invokeMethod('setAutoPip', false);
    }
    // Hand brightness back to the system when leaving the player.
    if (_gesturesEnabled) {
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (_) {},
      );
      // Re-enable the OS volume bar for the rest of the app.
      FlutterVolumeController.updateShowSystemUI(true);
    }
    WakelockPlus.disable();
    if (_ready) _c.close();
    // Detach from the app-level party controller (nulls out player hooks and,
    // if this client is host, marks the room lobby). Does NOT leave the party —
    // closing the player keeps the party alive in the background.
    if (_attached) {
      _room.removeListener(_roomListener);
      _room.detachPlayer();
    }
    // On TV the app is always landscape — restoring portrait here (correct for
    // phones) would squish the 10-foot layout into a narrow strip after exiting
    // the player. So on TV we restore landscape; phones keep portrait as before.
    SystemChrome.setPreferredOrientations(
      sl<AppMode>().isTv
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── Controls visibility ─────────────────────────────────────────────────

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      // Don't hide while paused (no auto-hide when not playing).
      if (mounted && _c.player.state.playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  /// Keep controls up and reset the auto-hide timer after any interaction.
  void _bumpControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  /// A tap landing on one of the three zones — sorts "toggle the controls" from
  /// "start a double-tap seek" without a recognizer stalling the arena.
  ///
  /// Hide and show are handled differently on purpose. Hiding runs on the spot:
  /// it's the direction you feel, and if the tap turns out to be a seek then
  /// hidden is where the bars wanted to be anyway. Showing waits out
  /// [_tapBurstWindow] first, because a reveal that the next tap has to take
  /// back is the blink you see mid-jump. The centre zone can't seek, so it
  /// skips the wait entirely and is instant both ways.
  void _tapZone(int dir) {
    final now = DateTime.now();
    final last = _lastZoneTapAt;
    final chained =
        last != null &&
        _lastZoneTapSide == dir &&
        now.difference(last) < _tapBurstWindow;
    _lastZoneTapAt = now;
    _lastZoneTapSide = dir;
    _zoneTapCount = chained ? _zoneTapCount + 1 : 1;

    if (dir == 0) {
      _cancelPendingShow();
      _toggleControls();
      return;
    }
    // Second (or later) tap on the same side: a seek. Rapid taps keep stacking
    // (−10s, −20s…) YouTube-style via _accumSeek.
    if (_zoneTapCount >= 2) {
      _cancelPendingShow();
      _seekZone(dir);
      return;
    }
    if (_controlsVisible) {
      _toggleControls();
    } else {
      _showTimer?.cancel();
      _showTimer = Timer(_tapBurstWindow, () {
        if (mounted) _bumpControls();
      });
    }
  }

  void _cancelPendingShow() {
    _showTimer?.cancel();
    _showTimer = null;
  }

  /// Double-tap one side to seek; rapid taps accumulate (−10s, −20s, −30s…)
  /// and the indicator shows on that side, YouTube-style.
  void _accumSeek(int dir) {
    HapticFeedback.lightImpact(); // tactile tick on each seek tap
    if (_seekSide != dir) {
      // Direction flipped mid-burst: commit whatever was pending the old way
      // first, then start a fresh count on the new side.
      _flushPendingSeek();
      _seekAccum = 0;
    }
    _seekSide = dir;
    _seekAccum += _seekSeconds;
    _pendingSeek += dir * _seekSeconds;
    _seekTick++; // re-key the indicator so its slide/fade replays each tap
    _seekLabelTimer?.cancel();
    setState(() {}); // the indicator updates instantly for immediate feedback
    // Debounce the real jump: only seek once tapping settles, so rapid taps are
    // one smooth jump instead of a re-buffer per tap.
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(
      const Duration(milliseconds: 350),
      _flushPendingSeek,
    );
    _seekLabelTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _seekSide = 0;
          _seekAccum = 0;
        });
      }
    });
    // Don't pop the full controls on a double-tap seek — show only the seek
    // indicator so the video/subtitles stay unobstructed (YouTube-style). Keep
    // the controls alive only if they were already showing.
    if (_controlsVisible) _scheduleHide();
  }

  /// Apply the accumulated (debounced) double-tap seek as a single jump.
  void _flushPendingSeek() {
    _seekDebounceTimer?.cancel();
    if (_pendingSeek != 0) {
      _c.seekBy(Duration(seconds: _pendingSeek));
      _pendingSeek = 0;
    }
  }

  // ── Gestures ────────────────────────────────────────────────────────────

  /// Double-tap a side zone to seek. dir −1 = left/rewind, +1 = right/forward.
  void _seekZone(int dir) => _accumSeek(dir);

  // Vertical swipe: left half adjusts screen brightness, right half adjusts
  // volume (MX/Netflix-style). Each drag seeds from the current value, then
  // tracks finger movement; a swipe across ~70% of the height covers 0→100%.
  Future<void> _onVDragStart(DragStartDetails d) async {
    if (!_gesturesEnabled) return;
    _lastHudPct = -1; // fresh swipe → don't tick on the first sample
    _dragIsBrightness =
        d.localPosition.dx < MediaQuery.of(context).size.width / 2;
    if (_dragIsBrightness) {
      try {
        _dragValue = await ScreenBrightness.instance.application;
      } catch (_) {
        _dragValue = 0.5;
      }
    } else {
      // CloudStream-style: the 0–200% slider maps 0–100% to the REAL system
      // volume and 100–200% to mpv's software boost. Seed from whichever is
      // active so the drag continues from the current level (1.0 = 200%).
      final boost = sl<PlaybackPrefs>().volumeBoost; // 100..200 (100 = no boost)
      final double combined = boost > 100
          ? boost / 100.0 // boosted → 1..2
          : (await FlutterVolumeController.getVolume()) ?? 0.5; // system → 0..1
      _dragValue = (combined / 2).clamp(0.0, 1.0);
    }
  }

  void _onVDragUpdate(DragUpdateDetails d) {
    if (!_gesturesEnabled || _pinching) return; // ignore once a pinch begins
    final h = MediaQuery.of(context).size.height;
    // Drag up (negative delta) increases the value.
    _dragValue = (_dragValue - d.primaryDelta! / (h * 0.7)).clamp(0.0, 1.0);
    if (_dragIsBrightness) {
      ScreenBrightness.instance
          .setApplicationScreenBrightness(_dragValue)
          .catchError((_) {});
    } else {
      // 0–200% slider: 0–100% drives the REAL system volume; >100% pins the
      // system at max and adds mpv's software gain (CloudStream's model).
      final combined = (_dragValue * 2).clamp(0.0, 2.0); // 0..2
      FlutterVolumeController.setVolume(combined.clamp(0.0, 1.0));
      final boost = combined <= 1.0 ? 100 : (combined * 100).round();
      if (boost != sl<PlaybackPrefs>().volumeBoost) _c.setVolumeBoost(boost);
    }
    // Haptic tick when the value crosses a landmark (min / system-max / boost).
    final pct = ((_dragIsBrightness ? 1 : 2) * _dragValue * 100).round();
    if (_lastHudPct >= 0) {
      for (final b in (_dragIsBrightness ? const [0, 100] : const [0, 100, 200])) {
        if ((_lastHudPct - b) * (pct - b) <= 0 && _lastHudPct != pct) {
          HapticFeedback.selectionClick();
          break;
        }
      }
    }
    _lastHudPct = pct;
    setState(() {
      _hudVisible = true;
      _hudValue = _dragValue;
      _hudIsBrightness = _dragIsBrightness;
    });
  }

  void _onVDragEnd(DragEndDetails d) {
    if (!_gesturesEnabled) return;
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  // Horizontal swipe across the surface scrubs the position; a time bubble shows
  // the target while dragging, and the seek commits on release.
  void _onHDragStart(DragStartDetails d) {
    if (!_swipeSeekEnabled) return;
    if (_duration <= Duration.zero) return; // can't scrub without a duration
    _hSeekStart = _c.player.state.position;
    _hSeekTarget = _hSeekStart;
    setState(() => _hSeeking = true);
  }

  void _onHDragUpdate(DragUpdateDetails d) {
    if (!_hSeeking || _pinching) return;
    final w = MediaQuery.of(context).size.width;
    // Map the full screen width to the whole duration, so a partial swipe can
    // reach anywhere (e.g. 7s → 20min) — like scrubbing the whole bar.
    final perPx = _duration.inMilliseconds / w;
    final deltaMs = (d.primaryDelta! * perPx).round();
    var t = _hSeekTarget.inMilliseconds + deltaMs;
    t = t.clamp(0, _duration.inMilliseconds);
    setState(() => _hSeekTarget = Duration(milliseconds: t));
  }

  void _onHDragEnd(DragEndDetails d) {
    if (!_hSeeking) return;
    _c.seekTo(_hSeekTarget);
    setState(() => _hSeeking = false);
    _bumpControls();
  }

  // ── Pinch-to-zoom — raw-pointer driven so it never fights the 1-finger
  // gestures above. Two fingers down → start; their spread sets the zoom and
  // their midpoint pans; releasing a finger ends it (snapping back to fit when
  // near 1×). The video is scaled by [_zoom]/[_zoomPan] in build(). ──────────
  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && !_locked) _startPinch();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pinching && _pointers.length >= 2) _updatePinch();
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _pinching) _endPinch();
  }

  void _startPinch() {
    final p = _pointers.values.toList();
    _pinchBaseDist = (p[0] - p[1]).distance;
    _pinchBaseFocal = Offset((p[0].dx + p[1].dx) / 2, (p[0].dy + p[1].dy) / 2);
    _pinchBaseZoom = _zoom;
    _pinchBasePan = _zoomPan;
    setState(() {
      _pinching = true;
      _hSeeking = false; // cancel any 1-finger scrub the first finger started
      _hudVisible = false; // and any brightness/volume HUD
    });
  }

  void _updatePinch() {
    if (_pinchBaseDist <= 0) return;
    final p = _pointers.values.toList();
    final dist = (p[0] - p[1]).distance;
    final focal = Offset((p[0].dx + p[1].dx) / 2, (p[0].dy + p[1].dy) / 2);
    final z = (_pinchBaseZoom * dist / _pinchBaseDist).clamp(1.0, 4.0);
    setState(() {
      _zoom = z;
      _zoomPan = _clampPan(_pinchBasePan + (focal - _pinchBaseFocal), z);
    });
  }

  void _endPinch() {
    setState(() {
      _pinching = false;
      if (_zoom < 1.08) {
        // pinched back near fit → snap cleanly to 1× and recentre
        _zoom = 1.0;
        _zoomPan = Offset.zero;
      }
    });
  }

  /// Keep the panned, zoomed video from sliding past its own edges.
  Offset _clampPan(Offset pan, double zoom) {
    final size = MediaQuery.of(context).size;
    final maxX = (zoom - 1) * size.width / 2;
    final maxY = (zoom - 1) * size.height / 2;
    return Offset(
      pan.dx.clamp(-maxX, maxX).toDouble(),
      pan.dy.clamp(-maxY, maxY).toDouble(),
    );
  }

  // ── Lock / zoom / up-next ─────────────────────────────────────────────────

  /// The user's control arrangement, re-read each build so a change made in
  /// Settings is live the moment you come back to the player.
  PlayerControlsConfig get _barConfig {
    final p = sl<PlaybackPrefs>();
    return PlayerControlsConfig(
      top: p.playerBarTop ?? PlayerControlsConfig.defaultTop,
      left: p.playerBarLeft ?? PlayerControlsConfig.defaultLeft,
      right: p.playerBarRight ?? PlayerControlsConfig.defaultRight,
    ).sanitised();
  }

  /// Settings, from the top bar. Pushed over the player rather than replacing
  /// it, so the session, position and resolved source survive — coming back
  /// picks up exactly where it left off.
  ///
  /// Playback is paused on the way in: the video is hidden behind the route,
  /// and audio carrying on under a settings list reads as a bug. It resumes
  /// on return only if it was actually playing when you left.
  Future<void> _openSettings() async {
    final wasPlaying = _c.player.state.playing;
    if (wasPlaying) _c.togglePlay();
    // Settings is built for portrait, but the player pins landscape and hides
    // the system bars — leaving that in place renders it sideways with no
    // status bar. Hand both back for the trip, then take them again on return.
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
    if (!mounted) return;
    // Back to whichever orientation you were watching in — not landscape by
    // default, or a portrait session would end up sideways after a settings trip.
    await SystemChrome.setPreferredOrientations(_orientationLock);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    if (wasPlaying && !_c.player.state.playing) _c.togglePlay();
    _bumpControls();
  }

  void _toggleLock() {
    setState(() {
      _locked = !_locked;
      if (_locked) {
        _controlsVisible = false;
      } else {
        _controlsVisible = true;
        _scheduleHide();
      }
    });
  }

  void _cycleFit() {
    setState(() => _fitIndex = (_fitIndex + 1) % _fits.length);
    _bumpControls(); // the top-bar zoom label reflects the new mode
  }

  /// The skip button for the current [pos]: an accurate AniSkip "Skip
  /// Shows "Skip opening/ending" ONLY when inside a real AniSkip interval
  /// (anime). No blind manual fallback — movies/series with no skip data never
  /// show an inaccurate "Skip intro".
  Widget? _skipButtonFor(Duration pos) {
    if (!_skipIntroEnabled) return null;
    for (final iv in _c.currentSkips) {
      // Hide a beat before the interval ends so it doesn't flicker at the edge.
      if (pos >= iv.start && pos < iv.end - const Duration(seconds: 1)) {
        return _SkipButton(
          label: 'Skip',
          onTap: () {
            _c.seekTo(iv.end);
            _bumpControls();
          },
        );
      }
    }
    return null;
  }

  /// MegaSkip: jump forward by the configured seconds (clamped to the end) and
  /// flash a brief "+Ns" indicator (Aniyomi-style). Independent of the accurate
  /// AniSkip OP/ED skip above.
  void _megaSkip() {
    _c.seekBy(Duration(seconds: _megaSkipSeconds));
    _bumpControls();
    _megaFlashTimer?.cancel();
    setState(() => _megaFlash = true);
    _megaFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _megaFlash = false);
    });
  }

  Future<void> _captureScreenshot() async {
    // Instant camera-flash feedback. It's a Flutter overlay (not in the mpv
    // frame), so it never corrupts the captured image.
    setState(() => _flashing = true);
    Future.delayed(const Duration(milliseconds: 130), () {
      if (mounted) setState(() => _flashing = false);
    });
    await _c.captureScreenshot(); // saves to gallery + toasts the result
    _bumpControls();
  }

  void _onEpisodeComplete() {
    // Sleep timer set to "end of episode" — stop here instead of advancing.
    if (_sleepEndOfEpisode) {
      _c.player.pause();
      setState(() {
        _sleepActive = false;
        _sleepEndOfEpisode = false;
      });
      if (_sleepCloseApp) SystemNavigator.pop(); // exit the app
      return;
    }
    final hasNext = _c.state.currentIndex + 1 < _c.episodes.length;
    if (!hasNext) return;
    if (!sl<PlaybackPrefs>().autoplayNext) return;
    _upNextTimer?.cancel();
    setState(() {
      _upNext = true;
      _upNextLeft = 5;
      _controlsVisible = false;
    });
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _upNextLeft -= 1);
      if (_upNextLeft <= 0) {
        t.cancel();
        _playUpNext();
      }
    });
  }

  void _playUpNext() {
    _upNextTimer?.cancel();
    setState(() => _upNext = false);
    _c.playNext(auto: true); // binge flow → honour "Auto-skip filler"
  }

  void _dismissUpNext() {
    _upNextTimer?.cancel();
    setState(() => _upNext = false);
  }

  // ── Anime4K enhancement (real-time GLSL upscaler) ─────────────────────────
  void _openEnhanceSheet() {
    // Shaders are downloaded on demand from Settings; if they aren't on disk
    // yet, point the user there instead of showing an inert list.
    if (!ShaderPresets.downloaded) {
      _sheet<void>(
        _SheetColumn(
          header: 'Anime4K Enhancement',
          children: [
            _SheetRow(
              label: 'Download in Settings',
              subtitle: 'Get the Anime4K shaders (~0.6 MB), then turn it on',
              active: false,
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      );
      return;
    }
    final prefs = sl<PlaybackPrefs>();
    final currentStyle = prefs.videoShaderStyle;
    final currentTier = prefs.videoShaderTier;
    _sheet<void>(
      _SheetColumn(
        header: 'Anime4K Enhancement',
        children: [
          for (final s in ShaderPresets.styles)
            _SheetRow(
              label: s.label,
              subtitle: s.description,
              active: s.id == currentStyle,
              onTap: () {
                Navigator.pop(context);
                _c.setShaderStyle(s.id);
                if (mounted) setState(() {}); // refresh the More icon state
                _bumpControls();
              },
            ),
          // GPU tier — how heavy the upscaler runs. Shown with what each does.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              'GPU TIER',
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                letterSpacing: 1.2,
              ),
            ),
          ),
          for (final t in ShaderPresets.tiers)
            _SheetRow(
              label: ShaderPresets.tierLabel(t),
              subtitle: ShaderPresets.tierDescription(t),
              active: t == currentTier,
              onTap: () {
                Navigator.pop(context);
                _c.setShaderTier(t);
                if (mounted) setState(() {});
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  // ── Colour adjustment (mpv equalizer sliders + quick presets) ─────────────
  void _openColorProfileSheet() {
    _sheet<void>(_ColorSheet(controller: _c, onInteract: _bumpControls));
  }

  // ── Episodes picker — slides in from the right (CloudStream-style) ─────────
  void _openEpisodesPanel() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Episodes',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, _) => Align(
        alignment: Alignment.centerRight,
        child: _EpisodesPanel(
          episodes: _c.episodes,
          currentIndex: _c.state.currentIndex,
          cover: widget.cover,
          coverHeaders: widget.coverHeaders,
          fillerEps: _c.fillerEpisodes.value,
          onSelect: (i) {
            Navigator.pop(ctx);
            if (i != _c.state.currentIndex) _c.openEpisode(i);
            _bumpControls();
          },
        ),
      ),
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  // ── Sleep timer ───────────────────────────────────────────────────────────
  void _openSleepSheet() {
    void choose(Duration? d, {bool endOfEpisode = false}) {
      Navigator.pop(context);
      _setSleep(d, endOfEpisode: endOfEpisode);
    }

    _sheet<void>(
      StatefulBuilder(
        builder: (context, setSheet) => _SheetColumn(
          header: 'Sleep timer',
          children: [
            _SheetRow(
              label: 'Off',
              active: !_sleepActive,
              onTap: () => choose(null),
            ),
            for (final m in const [5, 15, 30, 45, 60])
              _SheetRow(
                label: '$m minutes',
                active: false,
                onTap: () => choose(Duration(minutes: m)),
              ),
            _SheetRow(
              label: 'End of episode',
              active: _sleepEndOfEpisode,
              onTap: () => choose(null, endOfEpisode: true),
            ),
            _SheetRow(
              label: 'Close app when timer ends',
              subtitle: 'Exit the app to save battery',
              active: false,
              toggleValue: _sleepCloseApp,
              onTap: () => setSheet(() => _sleepCloseApp = !_sleepCloseApp),
            ),
          ],
        ),
      ),
    );
  }

  void _setSleep(Duration? d, {bool endOfEpisode = false}) {
    _sleepTimer?.cancel();
    setState(() {
      _sleepEndOfEpisode = endOfEpisode;
      _sleepActive = endOfEpisode || d != null;
    });
    if (d != null) {
      _sleepTimer = Timer(d, () {
        if (!mounted) return;
        _c.player.pause();
        setState(() => _sleepActive = false);
        if (_sleepCloseApp) SystemNavigator.pop(); // exit the app
      });
    }
    // Confirm what was armed — otherwise there's no sign the timer is on.
    final msg = endOfEpisode
        ? 'Sleep timer: end of this episode'
        : d != null
            ? 'Sleep timer set for ${d.inMinutes} min'
                '${_sleepCloseApp ? ' · closes the app' : ''}'
            : 'Sleep timer off';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    _bumpControls();
  }

  static String _fmtDur(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  Widget _buildUpNextCard() {
    final nextIdx = _c.state.currentIndex + 1;
    final next = nextIdx < _c.episodes.length ? _c.episodes[nextIdx] : null;
    final epNum = next?.number?.toInt() ?? (nextIdx + 1);
    final name = next?.title.trim() ?? '';
    final hasName = name.isNotEmpty && name.toLowerCase() != 'episode $epNum';
    // Thumbnail for the up-next episode (falls back to the show cover).
    final img = (next?.thumbnail?.trim().isNotEmpty ?? false)
        ? next!.thumbnail!.trim()
        : (widget.cover ?? '');
    return Align(
      alignment: const Alignment(0.95, 0.7),
      child: Container(
        width: 260,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.hairline, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (img.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: CachedNetworkImage(
                    imageUrl: img,
                    httpHeaders: widget.coverHeaders,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => Container(color: Colors.white10),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Text(
              'Up next in $_upNextLeft',
              style: AppText.caption.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 4),
            Text(
              hasName ? 'E$epNum · $name' : 'Episode $epNum',
              style: AppText.headline.copyWith(color: Colors.white),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _playUpNext,
                    child: Container(
                      height: 38,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Play now',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Semantics(
                  button: true,
                  label: 'Dismiss',
                  child: GestureDetector(
                    onTap: _dismissUpNext,
                    child: Container(
                      height: 38,
                      width: 38,
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Compact "Next Episode" pill shown bottom-right during the last ~75s, so the
  // user can advance manually before the auto "Up next" card kicks in. This is a
  // manual action, so it ignores the autoplayNext pref.
  Widget _buildOutroNextButton() {
    final hasNext = _c.state.currentIndex + 1 < _c.episodes.length;
    if (!hasNext) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: _positionBySecond,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = _c.player.state.duration;
        final remaining = dur - pos;
        final show =
            dur > Duration.zero && remaining <= const Duration(seconds: 75);
        if (!show) return const SizedBox.shrink();
        return Positioned(
          bottom: 16,
          right: 16,
          child: GestureDetector(
            onTap: _playUpNext,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.hairline, width: 0.5),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.skip_next, color: Colors.white, size: 20),
                  SizedBox(width: 6),
                  Text(
                    'Next Episode',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Sheets ──────────────────────────────────────────────────────────────

  Future<T?> _sheet<T>(Widget child) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SheetSurface(
        child: SafeArea(top: false, child: child),
      ),
    );
  }

  void _openSpeedSheet() {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final current = _c.player.state.rate;
    // Chips, not a list. Six rows at 52px each came to 388 — on a 393px-tall
    // landscape phone that's the entire screen, so you were picking a speed
    // with the video completely hidden behind the sheet. One wrapping row is
    // about a fifth of that, and you can see what the speed is doing to the
    // picture while you choose.
    _sheet<void>(
      _SheetChips(
        header: 'Playback Speed',
        labels: [for (final r in rates) r == 1.0 ? 'Normal' : '${r}x'],
        selected: rates.indexWhere((r) => (current - r).abs() < 0.01),
        onSelect: (i) {
          Navigator.pop(context);
          _c.setRateRemembered(rates[i]);
          _bumpControls();
        },
      ),
    );
  }

  /// Short label for the in-player decoder button.
  static String _shortDecoder(String mode) => switch (mode) {
        'direct' => 'HW',
        'sw' => 'SW',
        'auto' => 'AUTO',
        _ => 'HW+', // copy
      };

  /// In-player decoder switch (top-right). Applies LIVE — mpv re-inits the
  /// decoder in place, so a stuttering/green/black stream can be fixed without
  /// leaving the video.
  void _openDecoderSheet() {
    const modes = [
      ('copy', 'Hardware+ (recommended)'),
      ('direct', 'Hardware (faster)'),
      ('sw', 'Software (most compatible)'),
      ('auto', 'Auto'),
    ];
    final current = _c.decoderMode;
    _sheet<void>(
      _SheetColumn(
        header: 'Video decoder',
        children: [
          for (final (mode, label) in modes)
            _SheetRow(
              label: label,
              active: current == mode,
              onTap: () {
                Navigator.pop(context);
                _c.setDecoder(mode);
                _bumpControls();
                if (mounted) setState(() {});
              },
            ),
        ],
      ),
    );
  }

  /// Build the Flutter subtitle overlay style from the user's prefs. media_kit
  /// renders text subtitles via this [SubtitleViewConfiguration] (a Flutter
  /// overlay), NOT libass — so font/colour/size/outline/position all live here.
  /// The [TextStyle] comes from the shared [buildSubtitleTextStyle] so the live
  /// preview in the style sheet matches exactly what renders on the video.
  SubtitleViewConfiguration _subtitleConfig() {
    final p = sl<PlaybackPrefs>();
    // position 0 (top) … 100 (bottom). Higher value → nearer the bottom (less
    // bottom padding); lower value lifts the text up the frame.
    final pos = p.subtitlePosition.clamp(0, 100);
    final bottom = 16.0 + (100 - pos) * 3.0;
    return SubtitleViewConfiguration(
      textAlign: TextAlign.center,
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
      style: buildSubtitleTextStyle(p, fontSize: 32.0 * p.subtitleScale),
    );
  }

  /// Netflix-style combined Audio | Subtitles panel (two columns, live
  /// selection without closing).
  void _openAudioSubsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SheetSurface(
        blur: true,
        opacity: 0.82,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          top: false,
          child: _AudioSubsSheet(
            controller: _c,
            onInteract: _bumpControls,
            onLoadFile: () {
              Navigator.pop(context);
              _loadSubtitleFromFile();
            },
            onSearchOnline: () {
              Navigator.pop(context);
              _openOnlineSubtitleSheet();
            },
            onTranslate: () {
              Navigator.pop(context);
              _openTranslateSheet();
            },
          ),
        ),
      ),
    );
  }

  // ── Translate the active subtitle into a chosen language ──────────────────
  void _openTranslateSheet() {
    final pref = sl<PlaybackPrefs>().translateSubtitleTo;
    _sheet<void>(
      _SheetColumn(
        header: 'Translate subtitles to',
        children: [
          for (final lang in kSubtitleLanguages)
            _SheetRow(
              label: lang.name,
              active: lang.iso1 == pref,
              onTap: () {
                Navigator.pop(context);
                sl<PlaybackPrefs>().setTranslateSubtitleTo(lang.iso1);
                _c.translateCurrentSub(lang.iso1);
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  Future<void> _loadSubtitleFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'vtt', 'ass', 'ssa', 'sub'],
      );
      final path = result?.files.single.path;
      if (path != null) {
        await _c.setSubtitleFromFile(path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not load subtitle: $e')));
      }
    }
    _bumpControls();
  }

  /// Online subtitle search (OpenSubtitles). Prefills with the show title and,
  /// on tap, downloads the chosen subtitle then applies it to the player.
  void _openOnlineSubtitleSheet() {
    final initialQuery = (widget.showTitle?.trim().isNotEmpty ?? false)
        ? widget.showTitle!.trim()
        : (widget.scrobbleTitle?.trim() ?? '');
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SheetSurface(
        blur: true,
        opacity: 0.82,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          top: false,
          child: _OnlineSubtitleSheet(
            initialQuery: initialQuery,
            // Default the manual search to the preferred language, falling back
            // to English (the prior default) when no preference is set.
            initialLanguage:
                sl<PlaybackPrefs>().preferredSubtitleLanguage.isEmpty
                ? 'en'
                : sl<PlaybackPrefs>().preferredSubtitleLanguage,
            imdbId: widget.imdbId,
            tmdbId: widget.tmdbId,
            onApply: (path) async {
              await _c.setSubtitleFromFile(path);
              _bumpControls();
            },
          ),
        ),
      ),
    );
  }

  void _openQualitySheet() {
    // Prefer adaptive HLS-master variants when present (Auto + variants);
    // otherwise fall back to the distinct per-source qualities (e.g. AllAnime
    // mp4/clock sources that each carry a resolution but no HLS master).
    final List<Widget> rows;
    if (_c.state.qualities.isNotEmpty) {
      rows = [
        _SheetRow(
          label: 'Auto',
          active: _c.state.activeQuality == null,
          onTap: () {
            Navigator.pop(context);
            _c.chooseQuality(null);
            _bumpControls();
          },
        ),
        for (final v in _c.state.qualities)
          _SheetRow(
            label: v.quality,
            active: _c.state.activeQuality?.url == v.url,
            onTap: () {
              Navigator.pop(context);
              _c.chooseQuality(v);
              _bumpControls();
            },
          ),
      ];
    } else {
      rows = [
        for (final q in _c.sourceQualities)
          _SheetRow(
            label: q,
            active: _c.activeSourceQuality == q,
            onTap: () {
              Navigator.pop(context);
              _c.chooseSourceQuality(q);
              _bumpControls();
            },
          ),
      ];
    }
    _sheet<void>(_SheetColumn(header: 'Quality', children: rows));
  }

  void _openSourceSheet() {
    final kinds = availableKinds(_c.state.sources);
    _sheet<void>(
      _SheetColumn(
        header: 'Sources',
        children: [
          for (final k in kinds)
            for (final s in sortByQuality(sourcesForKind(_c.state.sources, k)))
              _SheetRow(
                // Prefer the provider's own per-mirror name (e.g. a HubCloud
                // server) AND append its resolution (e.g. "… · 1080p"), matching
                // how CloudStream shows it; fall back to kind + quality/container
                // when the source has no name of its own.
                label: s.label?.isNotEmpty == true
                    ? _sourceLabelWithQuality(s.label!, s.quality)
                    // Only prefix the audio kind when it's a real sub/dub — an
                    // `unknown` kind (e.g. Aniyomi sources) would otherwise read
                    // as a stray "UNKNOWN •".
                    : '${k != AudioKind.unknown ? '${k.name.toUpperCase()} • ' : ''}'
                          '${s.quality?.isNotEmpty == true ? s.quality : s.container.name}',
                active: s == _c.state.active,
                onTap: () {
                  Navigator.pop(context);
                  _c.selectSource(s); // remembers this source for the title
                  _bumpControls();
                },
              ),
        ],
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  // Loading backdrop: the episode poster (dimmed under a scrim) behind the
  // branded spinner, so tapping Play opens straight into a "player that's
  // loading" instead of a black screen while the source resolves + buffers —
  // the CloudStream-style instant-player feel. Purely visual; no logic change.
  Widget _loadingBackdropBody(String label, {String? thumb}) {
    final img = (thumb?.trim().isNotEmpty ?? false)
        ? thumb!.trim()
        : (widget.cover ?? '').trim();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (img.isNotEmpty)
          CachedNetworkImage(
            imageUrl: img,
            httpHeaders: widget.coverHeaders,
            fit: BoxFit.cover,
            // It's a dimmed, scrimmed backdrop behind the video — no need to
            // hold the full-res poster in memory.
            memCacheWidth: 1080,
            errorWidget: (c, u, e) => const ColoredBox(color: Colors.black),
            placeholder: (c, u) => const ColoredBox(color: Colors.black),
          ),
        // Scrim (top→bottom) so the spinner + label stay legible over art.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x99000000), Color(0xCC000000)],
            ),
          ),
        ),
        Center(child: BrandLoader(label: label)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // A Watch Together join that couldn't resolve the room's source — explain
    // it clearly instead of a blank/bouncing screen.
    if (_loadError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, color: Colors.white54, size: 44),
                  const SizedBox(height: 14),
                  Text(
                    _loadError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    // Still resolving the episode list (instant-nav path) — show the branded
    // loader instead of touching the not-yet-created cubit.
    if (!_ready) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _loadingBackdropBody('Loading…'),
      );
    }
    // One tooltip style for everything in the player, set here rather than on
    // each Tooltip: the top bar's stock IconButtons build their own from the
    // `tooltip:` property, so per-widget styling would leave those on Material's
    // default grey while ours were dark. Theming the whole subtree catches both.
    final scaffold = TooltipTheme(
      data: TooltipThemeData(
        decoration: BoxDecoration(
          // Same family as the control chips, just opaque enough to stay
          // readable over a bright frame — 0.3 like the bars would vanish.
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: AppText.caption.copyWith(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Scaffold(
      backgroundColor: Colors.black,
      body: BlocBuilder<PlayerCubit, PlayerState>(
        bloc: _c,
        builder: (context, state) {
          // Inside the PiP window: render ONLY the video — no overlay, no
          // gestures, no controls. The same controller keeps the texture live.
          if (_inPip) {
            return Center(
              child: Video(
                controller: _c.videoController,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              ),
            );
          }
          if (state.loadingSources) {
            return _loadingBackdropBody(
              'Finding the best source…',
              thumb: _c.currentEpisode.thumbnail,
            );
          }
          // Torrent source buffering: "Finding peers…" / "Buffering N%".
          if (state.torrentPhase != null) {
            return _loadingBackdropBody(
              state.torrentPhase!,
              thumb: _c.currentEpisode.thumbnail,
            );
          }
          if (state.error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 40,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      state.error!,
                      style: AppText.body,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => _c.openEpisode(state.currentIndex),
                      child: Text(
                        'Try again',
                        style: AppText.body.copyWith(color: AppColors.accent),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          // Reset any pinch-zoom when the episode changes.
          if (_zoomIndex != state.currentIndex) {
            _zoomIndex = state.currentIndex;
            _zoom = 1.0;
            _zoomPan = Offset.zero;
          }
          // Passive Listener tracks raw pointers for pinch-to-zoom so it never
          // competes with the 1-finger gesture detector inside the Stack.
          return Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. The video. NoVideoControls disables media_kit's built-in
              // controls (which include their own buffering spinner + gestures)
              // so ONLY our custom Netflix overlay shows — fixes the duplicate
              // spinner / double controls.
              Center(
                child: ValueListenableBuilder<int>(
                  valueListenable: _c.subtitleStyleRev,
                  builder: (context, _, _) => Transform.translate(
                    // Pinch-zoom: scale about centre, then pan. Overflow is
                    // clipped by the Stack so a zoomed frame crops to screen.
                    offset: _zoomPan,
                    child: Transform.scale(
                      scale: _zoom,
                      child: Video(
                        controller: _c.videoController,
                        controls: NoVideoControls,
                        fit: _fits[_fitIndex].$1,
                        subtitleViewConfiguration: _subtitleConfig(),
                      ),
                    ),
                  ),
                ),
              ),

              // 1b. Poster-on-start: cover the black surface with the episode's
              // poster until the first frame decodes, then fade it out. width
              // emits non-null/>0 once dimensions are known (≈ first frame), and
              // resets per new media so the poster re-shows each episode.
              Positioned.fill(
                child: StreamBuilder<int?>(
                  stream: _c.player.stream.width,
                  initialData: _c.player.state.width,
                  builder: (context, snap) {
                    final hasFrame = (snap.data ?? 0) > 0;
                    final img =
                        (_c.currentEpisode.thumbnail?.trim().isNotEmpty ?? false)
                        ? _c.currentEpisode.thumbnail!.trim()
                        : (widget.cover ?? '');
                    return IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: hasFrame || img.isEmpty ? 0 : 1,
                        duration: const Duration(milliseconds: 350),
                        child: img.isEmpty
                            ? const ColoredBox(color: Colors.black)
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  CachedNetworkImage(
                                    imageUrl: img,
                                    httpHeaders: widget.coverHeaders,
                                    fit: BoxFit.cover,
                                    errorWidget: (c, u, e) =>
                                        const ColoredBox(color: Colors.black),
                                  ),
                                  // subtle scrim so it reads as a player background
                                  const DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Color(0x33000000),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    );
                  },
                ),
              ),

              // 2. Input layer — D-pad on TV; touch gestures on phone.
              // On TV: PlayerTvControls owns the Focus/key-handler + bottom bar.
              // On phone: existing gesture surface (unchanged).
              if (sl<AppMode>().isTv)
                Positioned.fill(
                  child: PlayerTvControls(
                    onTogglePlay: _c.togglePlay,
                    onSeekBy: _c.seekBy,
                    onSpeed: _openSpeedSheet,
                    onAudioSubs: _openAudioSubsSheet,
                    onQuality: _openQualitySheet,
                    onSources: _openSourceSheet,
                    onFit: _cycleFit,
                    onNext: state.currentIndex + 1 < _c.episodes.length
                        ? () => _c.playNext()
                        : null,
                    onBack: () => Navigator.of(context).maybePop(),
                    playingStream: _c.player.stream.playing,
                    initialPlaying: _c.player.state.playing,
                    barVisible: _tvBarVisible,
                    onBarChange: (v) => setState(() => _tvBarVisible = v),
                    positionStream: _c.player.stream.position,
                    durationStream: _c.player.stream.duration,
                    initialPosition: _c.player.state.position,
                    initialDuration: _c.player.state.duration,
                    skipInfoFor: (pos) {
                      for (final iv in _c.currentSkips) {
                        if (pos >= iv.start &&
                            pos < iv.end - const Duration(seconds: 1)) {
                          return (
                            label: iv.type == 'ed'
                                ? 'Skip ending'
                                : 'Skip opening',
                            onSkip: () => _c.seekTo(iv.end),
                          );
                        }
                      }
                      return null;
                    },
                  ),
                )
              else if (_locked)
                // Locked: a single tap reveals the unlock button, nothing else.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControls,
                  ),
                )
              else
                // Phone: drags + long-press live on a bottom layer; taps live on
                // three zones stacked ABOVE it. Keeping tap off the drag detector
                // is the fix — a tap no longer competes with (and loses to) a pan
                // in the gesture arena, so show/hide is instant and reliable. The
                // centre zone is tap-only (instant toggle); the side zones add
                // double-tap-to-seek. Vertical = brightness/volume, horizontal =
                // scrub, long-press = 2× speed.
                Positioned.fill(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Drag + long-press layer (opaque, no tap handler).
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPressStart: _holdSpeedEnabled
                            ? (_) {
                                _c.setRate(2.0);
                                setState(() => _holding = true);
                              }
                            : null,
                        onLongPressEnd: _holdSpeedEnabled
                            ? (_) {
                                _c.setRate(1.0);
                                setState(() => _holding = false);
                              }
                            : null,
                        onVerticalDragStart: _onVDragStart,
                        onVerticalDragUpdate: _onVDragUpdate,
                        onVerticalDragEnd: _onVDragEnd,
                        // Nulled rather than no-op'd when the setting is off:
                        // a live recognizer still joins the gesture arena and
                        // would swallow any tap that drifted sideways, so the
                        // controls would stop toggling on a slightly sloppy tap.
                        onHorizontalDragStart: _swipeSeekEnabled
                            ? _onHDragStart
                            : null,
                        onHorizontalDragUpdate: _swipeSeekEnabled
                            ? _onHDragUpdate
                            : null,
                        onHorizontalDragEnd: _swipeSeekEnabled
                            ? _onHDragEnd
                            : null,
                      ),
                      // Tap zones — translucent so drags still reach the layer
                      // below. Thirds match the old seek trigger areas. The
                      // SizedBox.expand gives each zone a full-height hit area.
                      // All three carry a bare onTap (no double-tap recognizer,
                      // which would hold the arena and stall every single tap by
                      // 300ms); _tapZone sorts toggle from seek itself.
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () => _tapZone(-1),
                              child: const SizedBox.expand(),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () => _tapZone(0),
                              child: const SizedBox.expand(),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () => _tapZone(1),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              // 3. Buffering spinner when controls are hidden. Faded in/out
              // (not hard-popped) so a quick stall doesn't flash the spinner.
              StreamBuilder<bool>(
                stream: _c.player.stream.buffering,
                builder: (context, snap) {
                  final show = (snap.data ?? false) && !_controlsVisible;
                  return IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: show ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      // The spinner is kept mounted (so it can fade), but a
                      // CircularProgressIndicator spins forever via a repeating
                      // ticker — which scheduled a Flutter frame every vsync and
                      // pinned the whole player at 60fps even while invisible and
                      // the video sat idle. TickerMode freezes it unless it's
                      // actually showing, letting the panel fall to the video's
                      // real rate. The AnimatedOpacity's own ticker is outside
                      // this, so the fade still plays.
                      child: TickerMode(
                        enabled: show,
                        child: Center(
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: CircularProgressIndicator(
                              color: AppColors.accent,
                              strokeWidth: 2.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),

              // 3b. Transient status toast (e.g. auto-failover "Switching
              // server…" when a started source stalls), pinned near the top.
              ValueListenableBuilder<String?>(
                valueListenable: _c.toast,
                builder: (context, msg, _) {
                  if (msg == null) return const SizedBox.shrink();
                  return Positioned(
                    top: 16,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            msg,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),

              // 4. Double-tap seek indicator: an edge gradient
              // wash on the tapped side + an icon disc + the running total,
              // sliding/fading in. Re-keyed per tap so it replays each time.
              if (_seekSide != 0)
                _SeekIndicator(
                  key: ValueKey(_seekTick),
                  side: _seekSide,
                  accumSeconds: _seekAccum,
                ),

              // 4b. Brightness / volume HUD (MX/CloudStream-style) while swiping —
              // a side-rail bar pinned to the half being swiped; fades out on
              // release (auto-hide).
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hudVisible ? 1 : 0,
                  duration: Duration(milliseconds: _hudVisible ? 120 : 260),
                  curve: Curves.easeOut,
                  child: Align(
                    // Show the indicator on the OPPOSITE side to the swiping
                    // finger, so your hand doesn't cover it: brightness (left
                    // swipe) → right rail; volume (right swipe) → left rail.
                    alignment: _hudIsBrightness
                        ? const Alignment(0.88, 0.0) // brightness → RIGHT rail
                        : const Alignment(-0.88, 0.0), // volume → LEFT rail
                    child: _AdjustHud(
                      value: _hudValue,
                      isBrightness: _hudIsBrightness,
                    ),
                  ),
                ),
              ),

              // 5. 2x-hold chip (top-center). Same translucent-black chip as
              // the bottom bar rather than the old opaque surface2 block with
              // accent text. Carried a little more alpha than those, though:
              // holding for 2x doesn't raise the controls, so this sits on raw
              // video with no scrim under it to help legibility.
              if (_holding)
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.fast_forward_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '2×',
                              style: AppText.caption.copyWith(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

              // 4c. Horizontal drag-to-seek time bubble.
              if (_hSeeking)
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      child: Text(
                        '${_fmtDur(_hSeekTarget)} / ${_fmtDur(_duration)}',
                        style: AppText.headline.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ),

              // 6. Controls overlay (phone only — TV uses PlayerTvControls above).
              if (!sl<AppMode>().isTv && !_locked)
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  // Snappy pop-in, gentle fade-out; eased so it reads as fast.
                  duration: Duration(milliseconds: _controlsVisible ? 160 : 240),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _ControlsOverlay(
                      controller: _c,
                      state: state,
                      visible: _controlsVisible,
                      showTitle: widget.showTitle,
                      duration: _duration,
                      zoomLabel: _fits[_fitIndex].$2,
                      onDurationChanged: (d) {
                        if (mounted && d != _duration) {
                          setState(() => _duration = d);
                        }
                      },
                      onInteract: _bumpControls,
                      onRotate: _toggleOrientation,
                      portraitMode: _portraitMode,
                      onBack: () => Navigator.of(context).maybePop(),
                      onSpeed: _openSpeedSheet,
                      onAudioSubs: _openAudioSubsSheet,
                      onQuality: _openQualitySheet,
                      onSources: _openSourceSheet,
                      onLock: _toggleLock,
                      onSettings: _openSettings,
                      barConfig: _barConfig,
                      onZoom: _cycleFit,
                      onPip: _pipSupported ? _enterPip : null,
                      onSleep: _openSleepSheet,
                      sleepActive: _sleepActive,
                      decoderLabel: _shortDecoder(_c.decoderMode),
                      onDecoder: _openDecoderSheet,
                      onEpisodes: _c.episodes.length > 1
                          ? _openEpisodesPanel
                          : null,
                      onPrev: _c.state.currentIndex > 0
                          ? () {
                              _c.playPrevious();
                              _bumpControls();
                            }
                          : null,
                      megaSkipEnabled: _megaSkipEnabled,
                      megaSkipSeconds: _megaSkipSeconds,
                      onMegaSkip: _megaSkip,
                      onChat: (_room.room != null)
                          ? () => setState(() => _chatOpen = !_chatOpen)
                          : null,
                      onInfo: _infoFields.isEmpty
                          ? null
                          : () {
                              setState(
                                () => _infoPanelOpen = !_infoPanelOpen,
                              );
                              _bumpControls();
                            },
                      infoOpen: _infoPanelOpen,
                      showQuality: _alwaysShowQuality,
                      onScreenshot: _captureScreenshot,
                      onEnhance: _openEnhanceSheet,
                      enhanceActive:
                          sl<PlaybackPrefs>().videoShaderStyle != 'off',
                      onColorProfile: _openColorProfileSheet,
                    ),
                  ),
                )
              else if (!sl<AppMode>().isTv) // phone locked: show unlock button
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: Duration(milliseconds: _controlsVisible ? 160 : 240),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RoundIconButton(
                            icon: Icons.lock_rounded,
                            onTap: _toggleLock,
                            semanticLabel: 'Unlock controls',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap to unlock',
                            style: AppText.caption.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 6b. Player info overlay ("stats for nerds") — the fields the
              // user ticked in Settings, toggled by the ⓘ button (top-left,
              // below the top bar). Persists until toggled off.
              if (!sl<AppMode>().isTv &&
                  !_locked &&
                  _infoPanelOpen &&
                  _infoFields.isNotEmpty)
                Positioned(
                  left: 16,
                  top: MediaQuery.of(context).padding.top + 58,
                  child: IgnorePointer(
                    child: _InfoOverlay(controller: _c, fields: _infoFields),
                  ),
                ),

              // 6b-iii. Camera flash on screenshot capture.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _flashing ? 0.85 : 0,
                    duration: const Duration(milliseconds: 110),
                    child: const ColoredBox(color: Colors.white),
                  ),
                ),
              ),


              // 6c. Skip button — accurate AniSkip OP/ED intervals (anime) when
              // detected. Independent of the controls (stays visible like
              // Netflix). No blind/hardcoded fallback — the manual jump-forward
              // is MegaSkip (6c-ii) below.
              if (!_locked && !_upNext && !sl<AppMode>().isTv)
                StreamBuilder<Duration>(
                  stream: _positionBySecond,
                  builder: (context, snap) {
                    final btn = _skipButtonFor(snap.data ?? Duration.zero);
                    if (btn == null) return const SizedBox.shrink();
                    // Sit low (Netflix-style) while watching; slide up above the
                    // seek bar when the controls are showing so they never clash.
                    return AnimatedAlign(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      alignment: Alignment(0.94, _controlsVisible ? 0.4 : 0.74),
                      child: btn,
                    );
                  },
                ),

              // 6c-ii. MegaSkip lives in the control bar (above the seek bar)
              // inside _ControlsOverlay — see its `megaSkip*` params below.

              // 6c-iii. Brief centered "+Ns" flash right after a MegaSkip tap.
              if (_megaFlash)
                IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.keyboard_double_arrow_right_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '+${_megaSkipSeconds}s',
                            style: AppText.headline.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 6d. Outro "Next Episode" pill — lets the user jump ahead near
              // the end of the episode before the auto "Up next" card appears.
              // Only when controls are hidden — the control bar already has a
              // Next button, and this pill would overlap the bottom seek bar.
              if (!_locked && !_upNext && !_controlsVisible)
                _buildOutroNextButton(),

              // 7. Up-next card (auto-advance countdown).
              if (_upNext) _buildUpNextCard(),

              // 8. In-room chat panel — slides in from the right when _chatOpen.
              // Gated on an active room; collapsed when leaving.
              if (_room.room != null && _chatOpen)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  child: SafeArea(
                    left: false,
                    right: false,
                    child: RoomChatPanel(
                      controller: _room,
                      onClose: () => setState(() => _chatOpen = false),
                    ),
                  ),
                ),

              // 9. Cast remote panel — replaces the normal gesture + controls
              // layer while a Chromecast session is active. Consumes all taps so
              // the gesture layer underneath is inert during casting.
              AnimatedBuilder(
                animation: sl<CastController>(),
                builder: (context, _) {
                  final castCtrl = sl<CastController>();
                  if (castCtrl.state != CastState.connected) {
                    return const SizedBox.shrink();
                  }
                  return Positioned.fill(
                    child: _CastRemotePanel(
                      deviceName: castCtrl.deviceName ?? 'TV',
                      showTitle: widget.showTitle,
                      cover: widget.cover,
                      loadError: castCtrl.loadError,
                      onBack: () => Navigator.of(context).maybePop(),
                      onStop: () => castCtrl.stop(),
                    ),
                  );
                },
              ),
            ],
            ),
          );
        },
      ),
      ),
    );
    // On TV: wrap with a PopScope so the first Back press hides the bar
    // (and only the second press pops the route). On phone this is unchanged.
    if (sl<AppMode>().isTv) {
      return PopScope(
        canPop: !_tvBarVisible,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _tvBarVisible) setState(() => _tvBarVisible = false);
        },
        child: scaffold,
      );
    }
    // Phone: guard the close with the user's Close-confirmation setting.
    // 'direct' pops straight through (canPop true); the other two are vetoed
    // and routed to _handleCloseRequest. This catches the back button, the
    // system/gesture back, and the cast-panel back — all of which maybePop().
    return PopScope(
      canPop: sl<PlaybackPrefs>().closeConfirmation == 'direct',
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleCloseRequest();
      },
      child: scaffold,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Cast remote panel — shown full-screen while a Chromecast session is active.
// Hides the Video widget behind it and provides a seek bar + play/pause / ±10s
// / Stop casting controls bound to CastController's live position/duration.
// ─────────────────────────────────────────────────────────────────────────────

