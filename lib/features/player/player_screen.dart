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
import '../detail/cubit/detail_cubit.dart'
    show seasonOf, seasonsOf, cleanTitle;
import '../../core/cast/cast_controller.dart';
import '../../core/cast/cast_proxy.dart';
import '../watch_together/watch_together_controller.dart';
import '../watch_together/ui/room_panel.dart';
import '../../core/app_mode.dart';
import '../../core/tv/tv_focusable.dart';
import 'player_controller.dart';
import 'player_controls_config.dart';
import 'player_tv_controls.dart';
import 'seek_preview.dart';
import 'color_profiles.dart';
import 'shader_presets.dart';
import 'drm_player_screen.dart';

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
/// e.g. a CloudStream extractor's own proxy. Such a URL is already reachable and
/// header-injected, so it's handed to the external player as-is rather than
/// wrapped again (double-proxying breaks it).
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
  });

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
        sl<PlaybackPrefs>().externalPlayerPackage.isNotEmpty) {
      _launchExternalThenPop();
      return;
    }
    _initInApp();
  }

  void _initInApp() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
      });
      // Arm auto-PiP-on-leave natively (works on Android 8.0+, unlike the
      // plugin's OnLeavePiP which needs 12+) — gated by the Playback setting.
      // The manual PiP button is unaffected by this toggle.
      await _pipChannel.invokeMethod('setAutoPip', sl<PlaybackPrefs>().autoPip);
    } catch (_) {
      /* PiP just stays off */
    }
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
      // Header-gated source + a player that can't forward headers. Three cases:
      //  • already-local (a CloudStream extractor's own localhost proxy): hand
      //    it over as-is — it's already reachable + header-injected; wrapping it
      //    again double-proxies and breaks it.
      //  • DASH (.mpd): our proxy only rewrites HLS and external players can't do
      //    header-gated DASH → play in the built-in player (mpv handles it).
      //  • otherwise (remote header-gated HLS): hand the player our localhost
      //    proxy URL (no headers — the proxy injects them upstream).
      // MX/Just Player (header-forwarding) and non-header-gated sources never
      // reach this branch — the unchanged direct hand-off below covers them.
      final extPkg = sl<PlaybackPrefs>().externalPlayerPackage;
      var playUrl = src.url;
      var launchHeaders = src.headers ?? const <String, String>{};
      if (headerGatedButPlayerCant(src.headers, extPkg) &&
          !isLocalStreamUrl(src.url)) {
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
        package: sl<PlaybackPrefs>().externalPlayerPackage,
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
    sl<CastController>().removeListener(_onCastStateChanged);
    // Disarm auto-PiP so leaving the closed player can't trigger it.
    if (_pipSupported) _pipChannel.invokeMethod('setAutoPip', false);
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
                      onBack: () => Navigator.of(context).maybePop(),
                      onSpeed: _openSpeedSheet,
                      onAudioSubs: _openAudioSubsSheet,
                      onQuality: _openQualitySheet,
                      onSources: _openSourceSheet,
                      onLock: _toggleLock,
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

class _CastRemotePanel extends StatefulWidget {
  const _CastRemotePanel({
    required this.deviceName,
    required this.showTitle,
    required this.cover,
    required this.onBack,
    required this.onStop,
    this.loadError,
  });

  final String deviceName;
  final String? showTitle;
  final String? cover;
  final String? loadError;
  final VoidCallback onBack;
  final VoidCallback onStop;

  @override
  State<_CastRemotePanel> createState() => _CastRemotePanelState();
}

class _CastRemotePanelState extends State<_CastRemotePanel> {
  // While the user drags the seek thumb, hold the value locally so the live
  // cast position stream doesn't yank it back.
  double? _dragMs;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar — back + "Casting to <TV>" heading.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    tooltip: 'Back',
                    onPressed: widget.onBack,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.cast_connected,
                              color: AppColors.accent,
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Casting to ${widget.deviceName}',
                              style: AppText.caption.copyWith(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        if (widget.showTitle != null)
                          Text(
                            widget.showTitle!,
                            style: AppText.headline.copyWith(color: Colors.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Poster art (optional) + centre transport controls (or error).
            Expanded(
              child: widget.loadError != null
                  // ── Load-error state ──────────────────────────────────────
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.cast_connected,
                              color: Colors.white38,
                              size: 56,
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              "This source can't be cast — try another source.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  // ── Normal playback state ─────────────────────────────────
                  : AnimatedBuilder(
                      animation: sl<CastController>(),
                      builder: (context, _) {
                        final castCtrl = sl<CastController>();
                        final isPlaying = castCtrl.isPlaying;
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Optional poster thumbnail.
                            if (widget.cover != null && widget.cover!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 24),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: CachedNetworkImage(
                                    imageUrl: widget.cover!,
                                    height: 120,
                                    fit: BoxFit.contain,
                                    errorWidget: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                              ),

                            // Transport: −10s / play-pause / +10s.
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  iconSize: 40,
                                  icon: const Icon(
                                    Icons.replay_10,
                                    color: Colors.white,
                                  ),
                                  tooltip: 'Rewind 10 seconds',
                                  onPressed: () {
                                    final target =
                                        castCtrl.position -
                                        const Duration(seconds: 10);
                                    castCtrl.seek(
                                      target < Duration.zero
                                          ? Duration.zero
                                          : target,
                                    );
                                  },
                                ),
                                const SizedBox(width: 24),
                                IconButton(
                                  iconSize: 56,
                                  icon: Icon(
                                    isPlaying
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_filled,
                                    color: Colors.white,
                                  ),
                                  tooltip: isPlaying ? 'Pause' : 'Play',
                                  onPressed: () => isPlaying
                                      ? castCtrl.pause()
                                      : castCtrl.play(),
                                ),
                                const SizedBox(width: 24),
                                IconButton(
                                  iconSize: 40,
                                  icon: const Icon(
                                    Icons.forward_10,
                                    color: Colors.white,
                                  ),
                                  tooltip: 'Forward 10 seconds',
                                  onPressed: () {
                                    final dur = castCtrl.duration;
                                    final target =
                                        castCtrl.position +
                                        const Duration(seconds: 10);
                                    castCtrl.seek(
                                      dur > Duration.zero && target > dur
                                          ? dur
                                          : target,
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
            ),

            // Seek bar + stop button at the bottom.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: AnimatedBuilder(
                animation: sl<CastController>(),
                builder: (context, _) {
                  final castCtrl = sl<CastController>();
                  final pos = castCtrl.position;
                  final dur = castCtrl.duration;
                  final totalMs =
                      dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
                  final posMs = pos.inMilliseconds
                      .clamp(0, totalMs.toInt())
                      .toDouble();
                  final value = (_dragMs ?? posMs).clamp(0.0, totalMs);

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Time + seek bar + total — hidden when load failed.
                      if (widget.loadError == null) ...[
                        Row(
                          children: [
                            Text(
                              _fmt(Duration(milliseconds: value.round())),
                              style: AppText.caption.copyWith(color: Colors.white),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: AppColors.accent,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: Colors.white,
                                  overlayColor: AppColors.accentSoft,
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 7,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 16,
                                  ),
                                ),
                                child: Slider(
                                  min: 0,
                                  max: totalMs,
                                  value: value,
                                  onChangeStart: dur <= Duration.zero
                                      ? null
                                      : (v) => setState(() => _dragMs = v),
                                  onChanged: dur <= Duration.zero
                                      ? null
                                      : (v) => setState(() => _dragMs = v),
                                  onChangeEnd: dur <= Duration.zero
                                      ? null
                                      : (v) {
                                          castCtrl.seek(
                                            Duration(milliseconds: v.round()),
                                          );
                                          setState(() => _dragMs = null);
                                        },
                                ),
                              ),
                            ),
                            Text(
                              _fmt(dur),
                              style: AppText.caption.copyWith(color: Colors.white),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Stop casting button — always visible.
                      TextButton.icon(
                        onPressed: widget.onStop,
                        icon: const Icon(
                          Icons.cast,
                          color: Colors.white70,
                          size: 18,
                        ),
                        label: const Text(
                          'Stop casting',
                          style: TextStyle(color: Colors.white70),
                        ),
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white12,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Brightness / volume HUD — a compact dark side-rail bar with a percentage on
// top, a vertical fill track and an icon at the bottom, pinned to the half being
// swiped while the user drags (MX Player / CloudStream-style).
// ─────────────────────────────────────────────────────────────────────────────

class _AdjustHud extends StatelessWidget {
  const _AdjustHud({required this.value, required this.isBrightness});

  final double value; // 0..1
  final bool isBrightness;

  IconData get _icon {
    if (isBrightness) {
      return value < 0.35
          ? Icons.brightness_low_rounded
          : (value < 0.7
                ? Icons.brightness_medium_rounded
                : Icons.brightness_high_rounded);
    }
    return value <= 0.01
        ? Icons.volume_off_rounded
        : (value < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
  }

  @override
  Widget build(BuildContext context) {
    // Volume runs 0–200% (in-app boost); brightness stays 0–100%.
    final pct = ((isBrightness ? 1 : 2) * value * 100).round();
    // Tint the boost zone (>100%) red as a warning, like CloudStream.
    final boosted = !isBrightness && pct > 100;
    final fillColor = boosted ? Colors.red : AppColors.accent;
    // The track fill maps the full range onto 0..1 — volume is half-full at 100%.
    final fill = value.clamp(0.0, 1.0);
    final tint = boosted ? Colors.red : Colors.white;
    // Same translucent-black capsule as the transport discs and the bottom
    // chips — this was the last piece of the player still on its own look
    // (a near-opaque 0.78 slab with a glowing fill).
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Percentage on top. Tabular digits matter more here than anywhere
            // else in the player: this number changes continuously under your
            // thumb, and proportional figures make it jitter the whole way.
            Text(
              '$pct%',
              style: AppText.caption.copyWith(
                color: tint,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
                height: 1.1,
                letterSpacing: 0.3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
            // Vertical fill track (bottom-anchored). Accent, matching the seek
            // bar's played portion — but no glow: nothing else in the player
            // glows any more, and it was the loudest thing on screen.
            SizedBox(
              width: 6,
              height: 118,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedFractionallySizedBox(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      heightFactor: fill,
                      widthFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fillColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Icon at the bottom.
            Icon(_icon, color: tint, size: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Double-tap seek indicator — a soft side-anchored ripple with animated
// chevrons and the running ±Ns amount, YouTube-style. Re-pulses whenever the
// accumulated value changes (each rapid tap), and fades as the burst ends.
// ─────────────────────────────────────────────────────────────────────────────

class _SeekIndicator extends StatefulWidget {
  const _SeekIndicator({
    super.key,
    required this.side,
    required this.accumSeconds,
  });

  final int side; // -1 = rewind (left), +1 = forward (right)
  final int accumSeconds; // running total this burst (shown in the pill)

  @override
  State<_SeekIndicator> createState() => _SeekIndicatorState();
}

class _SeekIndicatorState extends State<_SeekIndicator>
    with SingleTickerProviderStateMixin {
  // Re-keyed per tap by the parent, so a fresh state replays the slide/fade-in.
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.side < 0;
    final curve = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: left ? const Alignment(-0.55, 0) : const Alignment(0.55, 0),
          child: FadeTransition(
            opacity: curve,
            child: SlideTransition(
              // Settle in from the tapped edge.
              position: Tween<Offset>(
                begin: Offset(left ? -0.06 : 0.06, 0),
                end: Offset.zero,
              ).animate(curve),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Accent icon disc — surface2 chip + a soft coral glow, the
                  // app's in-player signature (matches the 2× / volume chips).
                  Container(
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Semi-transparent so the video breathes through.
                      color: AppColors.surface2.withValues(alpha: 0.78),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accentSoft,
                          blurRadius: 16,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Icon(
                      left
                          ? Icons.fast_rewind_rounded
                          : Icons.fast_forward_rounded,
                      color: AppColors.accent,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Running-total pill (−/+ Ns) — same chip as the 2× hold pill.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface2.withValues(alpha: 0.78),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      child: Text(
                        '${left ? '−' : '+'}${widget.accumSeconds}s',
                        style: AppText.caption.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Controls overlay — top bar, center transport, bottom seek + button row.
// ─────────────────────────────────────────────────────────────────────────────

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.state,
    required this.showTitle,
    required this.duration,
    required this.onDurationChanged,
    required this.onInteract,
    required this.onBack,
    required this.onSpeed,
    required this.onAudioSubs,
    required this.onQuality,
    required this.onSources,
    required this.onLock,
    required this.onZoom,
    required this.zoomLabel,
    required this.onPrev,
    required this.onSleep,
    required this.sleepActive,
    required this.decoderLabel,
    required this.onDecoder,
    required this.onEpisodes,
    required this.megaSkipEnabled,
    required this.megaSkipSeconds,
    required this.onMegaSkip,
    this.onPip,
    this.onChat,
    this.onInfo,
    this.infoOpen = false,
    this.showQuality = false,
    required this.onScreenshot,
    required this.onEnhance,
    required this.enhanceActive,
    required this.onColorProfile,
    this.visible = true,
  });

  final PlayerCubit controller;
  final PlayerState state;
  final String? showTitle;
  final Duration duration;
  final ValueChanged<Duration> onDurationChanged;
  final VoidCallback onInteract;
  final VoidCallback onBack;
  final VoidCallback onSpeed;
  final VoidCallback onAudioSubs;
  final VoidCallback onQuality;
  final VoidCallback onSources;
  final VoidCallback onLock;
  final VoidCallback onZoom;
  final String zoomLabel;
  final VoidCallback? onPrev; // null = no previous episode
  final VoidCallback onSleep;
  final bool sleepActive;
  final String decoderLabel; // current decoder short label (HW/HW+/SW/AUTO)
  final VoidCallback onDecoder; // opens the in-player decoder picker
  final VoidCallback? onEpisodes; // null = single episode (no picker)
  final bool megaSkipEnabled; // MegaSkip pill above the seek bar
  final int megaSkipSeconds;
  final VoidCallback onMegaSkip;
  final VoidCallback? onPip; // null = PiP unsupported (hide the button)
  final VoidCallback? onChat; // in-room chat toggle (null = no active room)
  final VoidCallback? onInfo; // toggle the info panel (null = no fields picked)
  final bool infoOpen; // whether the info panel is currently shown
  final bool showQuality; // plain quality text on the top-bar right (with controls)
  final VoidCallback onScreenshot; // grab the current frame → gallery
  final VoidCallback onEnhance; // opens the video-enhancement (upscaler) picker
  final bool enhanceActive; // an upscaling preset is currently on
  final VoidCallback onColorProfile; // opens the colour-profile picker
  final bool visible; // drives the bars' slide-in (top drops, bottom rises)

  /// Overflow panel that slides in from the RIGHT (like the episodes panel) —
  /// holds the occasional actions so the control bars stay clean.
  void _showMore(BuildContext context) {
    onInteract();
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'More',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, _) {
        // Same width and surface as the episodes panel — this slides in from
        // the same edge with the same motion, so looking different was just
        // two panels wearing two skins. 40% was wider than it needed to be
        // for a short list of labels, too.
        final w = (MediaQuery.of(ctx).size.width * 0.33).clamp(250.0, 360.0);
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: FrostedSurface(
              blur: true,
              opacity: 0.88,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(20),
              ),
              // Left inset dropped for the same reason as the episodes panel:
              // this is pinned to the RIGHT edge, so padding it away from a
              // cutout on the opposite side just eats its width.
              child: SafeArea(
                left: false,
                child: SizedBox(
                  width: w,
                  height: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 13, 8, 9),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('More', style: AppText.title),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                color: AppColors.textSecondary,
                              ),
                              tooltip: 'Close',
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: AppColors.hairline, height: 1),
                      const SizedBox(height: 4),
                    _MoreRow(
                      icon: Icons.memory_rounded,
                      label: 'Decoder · $decoderLabel',
                      onTap: () {
                        Navigator.pop(ctx);
                        onDecoder();
                      },
                    ),
                    _MoreRow(
                      icon: enhanceActive
                          ? Icons.auto_awesome_rounded
                          : Icons.auto_awesome_outlined,
                      label: 'Anime4K Enhancement',
                      onTap: () {
                        Navigator.pop(ctx);
                        onEnhance();
                      },
                    ),
                    _MoreRow(
                      icon: Icons.palette_outlined,
                      label: 'Colour',
                      onTap: () {
                        Navigator.pop(ctx);
                        onColorProfile();
                      },
                    ),
                    _MoreRow(
                      icon: Icons.photo_camera_rounded,
                      label: 'Snapshot',
                      onTap: () {
                        Navigator.pop(ctx);
                        onScreenshot();
                      },
                    ),
                    _MoreRow(
                      icon: sleepActive
                          ? Icons.bedtime_rounded
                          : Icons.bedtime_outlined,
                      label: 'Sleep timer',
                      onTap: () {
                        Navigator.pop(ctx);
                        onSleep();
                      },
                    ),
                      if (onPip != null)
                        _MoreRow(
                          icon: Icons.picture_in_picture_alt_rounded,
                          label: 'Picture-in-picture',
                          onTap: () {
                            Navigator.pop(ctx);
                            onPip!();
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  /// Turns saved control ids into real buttons.
  ///
  /// The availability rules that were baked into the old fixed row still
  /// apply on top of the user's arrangement — Quality with nothing to pick
  /// between, Episodes on a single-episode item and PiP where the device
  /// doesn't support it drop out even if they've been placed on the bar.
  /// Anything unrecognised is skipped rather than crashing, which is what
  /// makes a layout saved by a newer build safe to load.
  List<Widget> _barButtons(BuildContext context, List<String> ids) {
    final c = controller;
    final hasQuality =
        state.qualities.isNotEmpty || c.sourceQualities.length > 1;
    final out = <Widget>[];
    for (final id in ids) {
      switch (id) {
        case 'speed':
          out.add(_BarButton(
            icon: Icons.speed_rounded,
            tooltip: 'Playback speed',
            onTap: onSpeed,
          ));
        case 'tracks':
          out.add(_BarButton(
            icon: Icons.subtitles_rounded,
            tooltip: 'Audio & subtitles',
            onTap: onAudioSubs,
          ));
        case 'quality':
          if (hasQuality) {
            out.add(_BarButton(
              icon: Icons.high_quality_rounded,
              tooltip: 'Quality',
              onTap: onQuality,
            ));
          }
        case 'sources':
          out.add(_BarButton(
            icon: Icons.layers_rounded,
            tooltip: 'Sources',
            onTap: onSources,
          ));
        case 'more':
          out.add(_BarButton(
            icon: Icons.more_vert_rounded,
            tooltip: 'More',
            onTap: () => _showMore(context),
          ));
        case 'episodes':
          if (onEpisodes != null) {
            out.add(_BarButton(
              icon: Icons.video_library_outlined,
              tooltip: 'Episodes',
              onTap: onEpisodes!,
            ));
          }
        case 'fit':
          out.add(_BarButton(
            // The icon carries the mode now that the label is gone, so the
            // button still says which one you're on.
            icon: _fitIcon(zoomLabel),
            tooltip: 'Aspect ratio · $zoomLabel',
            onTap: onZoom,
          ));
        case 'decoder':
          out.add(_BarButton(
            icon: Icons.memory_rounded,
            tooltip: 'Decoder · $decoderLabel',
            onTap: onDecoder,
          ));
        case 'enhance':
          out.add(_BarButton(
            icon: enhanceActive
                ? Icons.auto_awesome_rounded
                : Icons.auto_awesome_outlined,
            tooltip: 'Anime4K enhancement',
            onTap: onEnhance,
          ));
        case 'colour':
          out.add(_BarButton(
            icon: Icons.palette_outlined,
            tooltip: 'Colour',
            onTap: onColorProfile,
          ));
        case 'snapshot':
          out.add(_BarButton(
            icon: Icons.photo_camera_rounded,
            tooltip: 'Snapshot',
            onTap: onScreenshot,
          ));
        case 'sleep':
          out.add(_BarButton(
            icon: sleepActive
                ? Icons.bedtime_rounded
                : Icons.bedtime_outlined,
            tooltip: 'Sleep timer',
            onTap: onSleep,
          ));
        case 'pip':
          if (onPip != null) {
            out.add(_BarButton(
              icon: Icons.picture_in_picture_alt_rounded,
              tooltip: 'Picture-in-picture',
              onTap: onPip!,
            ));
          }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ep = c.currentEpisode;
    final epNum = ep.number?.toInt() ?? state.currentIndex + 1;
    // The episode's own name, but only when it's more than a generic
    // "Episode N" / bare number (many sources just echo the number there).
    final epName = ep.title.trim();
    final hasEpName =
        epName.isNotEmpty &&
        epName.toLowerCase() != 'episode $epNum' &&
        epName != '$epNum';
    // Line 1 = show name (falls back to "Episode N" when no show title).
    final primaryTitle = showTitle ?? 'Episode $epNum';
    // Line 2 = "E5 · Episode Name" — only when there's a show name above it to
    // pair with (otherwise line 1 already carries the episode number).
    final secondaryTitle = showTitle == null
        ? null
        : 'E$epNum${hasEpName ? ' · $epName' : ''}';
    // Quality appended to the E-line (reDantotsu-style) when enabled — prefers
    // the source's quality label, else the live video height (e.g. "1080p").
    String? qualityLabel;
    if (showQuality) {
      final q = state.active?.quality?.trim();
      if (q != null && q.isNotEmpty && q.toLowerCase() != 'auto') {
        qualityLabel = q;
      } else {
        final h = c.player.state.height ?? 0;
        if (h > 0) qualityLabel = '${h}p';
      }
    }
    final secondaryLine = qualityLabel == null
        ? secondaryTitle
        : (secondaryTitle == null
              ? qualityLabel
              : '$secondaryTitle · $qualityLabel');
    final hasNext = state.currentIndex + 1 < c.episodes.length;
    // Movies and one-off items have nowhere to step, so they get a lone play
    // button rather than two arrows that can never do anything.
    final multiEpisode = c.episodes.length > 1;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Top scrim.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 110,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x59000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        // Bottom scrim. There were two of these stacked at each end — 0xCC over
        // 0x99 up top, 0xE6 over 0xB3 down here — which is why showing the
        // controls dropped a heavy curtain over the video. One gentle pass each
        // way is plenty to keep white text legible on a bright frame.
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 170,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x8C000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),

        // Top bar.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            // Vertical insets only. Now that the window draws into the display
            // cutout, the horizontal safe inset is the camera's — and it exists
            // on one edge only, so honouring it shunts the whole bar sideways
            // and the margins stop matching. The cutout sits mid-edge; this bar
            // is pinned to the top, so they never meet.
            left: false,
            right: false,
            child: Padding(
              // 32, not the bottom block's 44, and the difference is on
              // purpose: these are IconButtons, which reserve 12px around the
              // glyph before it draws (8 default padding, plus 4 stretching the
              // 40px button out to the 48px minimum touch target). 32 + 12 puts
              // the back arrow on 44 — the exact line the bottom capsules start
              // at. Writing 44 here would land it at 56 and overshoot inward.
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    tooltip: 'Back',
                    onPressed: onBack,
                  ),
                  // Text hit-tests as opaque (RenderParagraph.hitTestSelf is
                  // true), so the title used to eat taps aimed at the video —
                  // a wide dead strip across the top where tapping did nothing.
                  // Nothing here is interactive, so let taps fall through to the
                  // zones below and toggle the controls like anywhere else.
                  Expanded(
                    child: IgnorePointer(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  primaryTitle,
                                  style: AppText.headline.copyWith(
                                    color: Colors.white,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (ep.filler) ...[
                                const SizedBox(width: 8),
                                const TagBadge(
                                  text: 'FILLER',
                                  color: AppColors.textTertiary,
                                ),
                              ],
                            ],
                          ),
                          if (secondaryLine != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                secondaryLine,
                                style: AppText.caption.copyWith(
                                  color: Colors.white70,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Cast button: Android only, shown whenever the Cast framework
                  // is supported (like YouTube — always visible once Cast is
                  // available; tapping opens the chooser + triggers discovery).
                  if (Platform.isAndroid)
                    AnimatedBuilder(
                      animation: sl<CastController>(),
                      builder: (context, _) {
                        final castCtrl = sl<CastController>();
                        if (!castCtrl.castSupported) {
                          return const SizedBox.shrink();
                        }
                        return IconButton(
                          icon: Icon(
                            castCtrl.state == CastState.connected
                                ? Icons.cast_connected
                                : Icons.cast,
                            color: Colors.white,
                          ),
                          tooltip: 'Cast',
                          onPressed: () => castCtrl.pickDevice(),
                        );
                      },
                    ),
                  // Info-panel toggle — the "stats for nerds" overlay.
                  if (onInfo != null)
                    IconButton(
                      icon: Icon(
                        Icons.info_outline_rounded,
                        color: infoOpen ? AppColors.accent : Colors.white,
                      ),
                      tooltip: 'Playback stats',
                      onPressed: onInfo,
                    ),
                  // Sleep timer armed — a visible accent moon; tap to adjust or
                  // cancel. Only shown while a timer / end-of-episode is set.
                  if (sleepActive)
                    IconButton(
                      icon: Icon(Icons.bedtime_rounded,
                          color: AppColors.accent),
                      tooltip: 'Sleep timer on',
                      onPressed: onSleep,
                    ),
                  // Episodes and ⋮ More live in the bottom bar now — a second
                  // copy up here just split the same action across two places.
                  // Lock stays: it's the one control you want reachable without
                  // looking down at the bar you're about to hide.
                  IconButton(
                    icon: const Icon(
                      Icons.lock_open_rounded,
                      color: Colors.white,
                    ),
                    tooltip: 'Lock controls',
                    onPressed: onLock,
                  ),
                  if (onChat != null)
                    IconButton(
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: Colors.white,
                      ),
                      tooltip: 'Chat',
                      onPressed: onChat,
                    ),
                ],
              ),
            ),
          ),
        ),

        // Centre transport — episode step either side of play/pause. The ±10s
        // buttons used to live here, but they jumped a hardcoded 10s while
        // double-tap honoured the user's Double-tap skip setting, so the two
        // disagreed; seeking is covered by double-tap, drag-to-seek and the
        // MegaSkip pill, all of which read the same preference.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (multiEpisode) ...[
                _TransportButton(
                  icon: Icons.skip_previous_rounded,
                  label: 'Previous episode',
                  onTap: onPrev,
                ),
                const SizedBox(width: 24),
              ],
              StreamBuilder<bool>(
                stream: c.player.stream.buffering,
                builder: (context, bSnap) {
                  final buffering = bSnap.data ?? c.player.state.buffering;
                  // While buffering, show the spinner IN PLACE OF the play/pause
                  // button — no more spinner-over-button overlap. 58px matches
                  // _AnimatedPlayPause's disc exactly, so the episode arrows
                  // don't twitch every time playback stalls.
                  if (buffering) {
                    return const SizedBox(
                      width: 58,
                      height: 58,
                      child: Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 3,
                          ),
                        ),
                      ),
                    );
                  }
                  return StreamBuilder<bool>(
                    stream: c.player.stream.playing,
                    builder: (context, snap) {
                      final playing = snap.data ?? c.player.state.playing;
                      return _AnimatedPlayPause(
                        playing: playing,
                        onTap: () {
                          c.togglePlay();
                          onInteract();
                        },
                      );
                    },
                  );
                },
              ),
              if (multiEpisode) ...[
                const SizedBox(width: 24),
                _TransportButton(
                  icon: Icons.skip_next_rounded,
                  label: 'Next episode',
                  onTap: hasNext
                      ? () {
                          c.playNext();
                          onInteract();
                        }
                      : null,
                ),
              ],
            ],
          ),
        ),

        // Bottom: seek row + buttons. Rises into place as it fades in — the
        // motion reads as instant even when the tap resolves a beat later.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.14),
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            child: SafeArea(
            top: false,
            // Vertical inset only — the bottom one keeps the bar clear of the
            // gesture nav. See the top bar for why the horizontal cutout inset
            // is skipped: it lands on one edge only and pushed this whole block
            // sideways, leaving a fat gap on the camera side and a thin one
            // opposite. The camera sits mid-edge, well clear of this bar.
            left: false,
            right: false,
            child: Padding(
              // One margin for the whole block — timestamp, progress bar and
              // both button groups share it, so every edge lines up. Kept wide
              // so the controls sit clear of the screen edges.
              padding: const EdgeInsets.fromLTRB(44, 0, 44, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Duration tracker (off-screen listener via StreamBuilder).
                  StreamBuilder<Duration>(
                    stream: c.player.stream.duration,
                    builder: (context, snap) {
                      final d = snap.data ?? duration;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (d > Duration.zero) onDurationChanged(d);
                      });
                      return _SeekRow(
                        controller: c,
                        duration: d > Duration.zero ? d : duration,
                        onInteract: onInteract,
                        // MegaSkip — manual jump-forward, riding the timestamp's
                        // line rather than a row of its own above it.
                        trailing: megaSkipEnabled
                            ? _MegaSkipPill(
                                seconds: megaSkipSeconds,
                                onTap: onMegaSkip,
                              )
                            : null,
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  // Control bar under the progress bar: the pickers ride in one
                  // translucent group on the left, episode list + fit mode in
                  // another on the right. Two groups rather than seven floating
                  // chips — the split reads at a glance, and every button is the
                  // same width so nothing shifts as the video changes.
                  Builder(
                    builder: (context) {
                      // Rendered from the user's saved arrangement rather than
                      // a fixed row. Untouched prefs give the defaults, which
                      // are the exact layout that shipped before the Settings
                      // screen existed — so nobody's bar moves unless they
                      // move it.
                      final prefs = sl<PlaybackPrefs>();
                      final cfg = PlayerControlsConfig(
                        left:
                            prefs.playerBarLeft ??
                            PlayerControlsConfig.defaultLeft,
                        right:
                            prefs.playerBarRight ??
                            PlayerControlsConfig.defaultRight,
                      ).sanitised();
                      final left = _barButtons(context, cfg.left);
                      final right = _barButtons(context, cfg.right);
                      return Row(
                        children: [
                          if (left.isNotEmpty) _BarGroup(children: left),
                          const Spacer(),
                          if (right.isNotEmpty) _BarGroup(children: right),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seek row — current time + slider (stream-bound) + total time.
// ─────────────────────────────────────────────────────────────────────────────

class _SeekRow extends StatefulWidget {
  const _SeekRow({
    required this.controller,
    required this.duration,
    required this.onInteract,
    this.trailing,
  });

  final PlayerCubit controller;
  final Duration duration;
  final VoidCallback onInteract;

  /// Sits at the far end of the timestamp's line (the MegaSkip pill). Riding
  /// the same row costs no extra height — it used to own a line to itself,
  /// which pushed it well clear of the bar it belongs to.
  final Widget? trailing;

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  // While the user is dragging the thumb, hold the value locally so the live
  // position stream doesn't yank it back (which made it feel un-draggable).
  double? _dragMs;

  // The live thumb only creeps forward, but the raw position stream fires ~once
  // per decoded frame — so the whole Slider (with its custom buffered track)
  // rebuilt every frame while the controls were up, dragging the panel down to
  // a GPU-bound ~20fps. Sample to ~4Hz: invisible for a slowly-advancing thumb,
  // and scrubbing stays perfectly smooth because it runs off _dragMs, not this.
  late final Stream<Duration> _livePosition = widget
      .controller.player.stream.position
      .map((p) => Duration(milliseconds: (p.inMilliseconds ~/ 250) * 250))
      .distinct();

  // Tap the right-hand time to flip between total duration and remaining time
  // (a negative countdown, e.g. "−1:00"), CloudStream-style.
  bool _showRemaining = false;

  // Netflix-style scrub preview: a hidden second player/decoder renders the
  // frame at the drag position. Kept alive for the whole session so only the
  // first scrub pays the open cost; online (mpv) re-opening every drag is what
  // made the box take ages to appear.
  SeekPreview? _preview;
  bool _prewarmed = false;

  // Open the online (mpv) preview engine ahead of the first drag so the stream
  // is already loaded by the time the user scrubs — avoids the long "hold and
  // wait" for the box to appear. Offline (MMR) is instant, so no pre-warm.
  void _maybePrewarm() {
    // Online scrub preview removed (see _previewEnabled) — this stays inert:
    // the local check returns for downloads, and online no longer enables.
    if (_prewarmed) return;
    final c = widget.controller;
    if (c.previewUri == null || c.isLocalMedia) return;
    if (!sl<PlaybackPrefs>().seekPreviewOnline) return;
    _prewarmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensurePreview();
      _preview?.request(c.player.state.position);
    });
  }

  bool get _previewEnabled {
    final c = widget.controller;
    if (c.previewUri == null) return false;
    // Online scrub preview removed — the hidden second-mpv engine was flaky
    // (screenshots often came back empty) and re-downloaded the stream just to
    // make thumbnails. Only local (download) previews remain: instant and free.
    return c.isLocalMedia;
    // return c.isLocalMedia || sl<PlaybackPrefs>().seekPreviewOnline;
  }

  void _ensurePreview() {
    final c = widget.controller;
    if (!_previewEnabled) {
      _preview?.dispose();
      _preview = null;
      return;
    }
    // Recreate if the active source changed (quality/source switch) so we don't
    // preview a stale URL.
    if (_preview != null && _preview!.uri != c.previewUri) {
      _preview!.dispose();
      _preview = null;
    }
    _preview ??= SeekPreview(
      uri: c.previewUri!,
      headers: c.previewHeaders,
      local: c.isLocalMedia,
    );
  }

  void _requestPreview(double ms) =>
      _preview?.request(Duration(milliseconds: ms.round()));

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    _maybePrewarm();
    final totalMs = widget.duration.inMilliseconds;
    final max = totalMs > 0 ? totalMs.toDouble() : 1.0;
    return StreamBuilder<Duration>(
      stream: _livePosition,
      builder: (context, snap) {
        final streamMs = (snap.data ?? Duration.zero).inMilliseconds
            .clamp(0, max.toInt())
            .toDouble();
        // Use the drag value while scrubbing, else the live position.
        final value = (_dragMs ?? streamMs).clamp(0.0, max);
        final shownPos = Duration(milliseconds: value.round());
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Elapsed / total sits above the bar so the bar itself can run the
            // full width — easier to scrub, and it reads as one clean line.
            // Tapping still flips the total for a remaining countdown. Anything
            // passed as [trailing] shares this line at the far end.
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _showRemaining = !_showRemaining);
                    widget.onInteract();
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                // Same translucent chip as the button groups, so the whole
                // bottom block reads as one set of parts.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      '${_fmt(shownPos)} / ${_showRemaining ? '-${_fmt(widget.duration - shownPos)}' : _fmt(widget.duration)}',
                      style: AppText.caption.copyWith(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                        letterSpacing: 0.3,
                        // Fixed-width digits: without these the label twitches
                        // every time a 1 ticks past, since 1 is narrower than
                        // the rest in a proportional face.
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                  ),
                ),
                if (widget.trailing != null) ...[
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: widget.trailing!,
                  ),
                ],
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: LayoutBuilder(
                builder: (context, cons) {
                  final w = cons.maxWidth;
                  final frac = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;
                  const bubbleW = 168.0;
                  final left = (frac * w - bubbleW / 2).clamp(
                    0.0,
                    (w - bubbleW).clamp(0.0, double.infinity),
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        width: w,
                        child: StreamBuilder<Duration>(
                          stream: widget.controller.player.stream.buffer,
                          builder: (context, bufSnap) {
                            final bufMs =
                                (bufSnap.data ?? Duration.zero).inMilliseconds;
                            final bufferedFrac = totalMs > 0
                                ? (bufMs / totalMs).clamp(0.0, 1.0)
                                : 0.0;
                            return SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: AppColors.accent,
                                inactiveTrackColor: Colors.white24,
                                trackShape: _BufferedSliderTrackShape(
                                  buffered: bufferedFrac,
                                  bufferedColor: Colors.white.withValues(
                                    alpha: 0.55,
                                  ),
                                  marks: [
                                    if (totalMs > 0 &&
                                        sl<PlaybackPrefs>().skipIntro)
                                      for (final iv
                                          in widget.controller.currentSkips) ...[
                                        (iv.start.inMilliseconds / totalMs)
                                            .clamp(0.0, 1.0),
                                        (iv.end.inMilliseconds / totalMs)
                                            .clamp(0.0, 1.0),
                                      ],
                                  ],
                                ),
                                thumbColor: Colors.white,
                                overlayColor: AppColors.accentSoft,
                                trackHeight: 6,
                                // Thumb grows while scrubbing (YouTube-style).
                                thumbShape: RoundSliderThumbShape(
                                  enabledThumbRadius: _dragMs != null ? 11 : 7,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 18,
                                ),
                              ),
                              child: Slider(
                                min: 0,
                                max: max,
                                value: value,
                                // Replaces the default inset — half the overlay
                                // width (~18px) horizontally, the overlay height
                                // vertically, which was most of the dead space
                                // around the bar. Horizontal is the thumb radius
                                // exactly: the thumb centres on the track's end,
                                // so anything less and half the dot hangs past
                                // the line the chips above and below sit on.
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 6,
                                ),
                                onChangeStart: totalMs <= 0
                                    ? null
                                    : (v) {
                                        _ensurePreview();
                                        setState(() => _dragMs = v);
                                        _requestPreview(v);
                                        widget.onInteract();
                                      },
                                onChanged: totalMs <= 0
                                    ? null
                                    : (v) {
                                        setState(() => _dragMs = v);
                                        _requestPreview(v);
                                        widget.onInteract();
                                      },
                                onChangeEnd: totalMs <= 0
                                    ? null
                                    : (v) {
                                        widget.controller.seekTo(
                                          Duration(milliseconds: v.round()),
                                        );
                                        setState(() => _dragMs = null);
                                        widget.onInteract();
                                      },
                              ),
                            );
                          },
                        ),
                      ),
                      // Off-screen 1px Video that drives mpv frame rendering
                      // for online previews — mpv only produces screenshot-able
                      // frames when its texture is actually painted. Kept
                      // mounted whenever the preview player exists (not only
                      // mid-drag) so it stays warm between scrubs.
                      if (_preview != null && _preview!.usesVideo)
                        Positioned(
                          left: 0,
                          top: 0,
                          width: 1,
                          height: 1,
                          child: IgnorePointer(
                            child: ValueListenableBuilder<VideoController?>(
                              valueListenable: _preview!.videoController,
                              builder: (context, vc, _) => vc == null
                                  ? const SizedBox.shrink()
                                  : Video(
                                      controller: vc,
                                      controls: NoVideoControls,
                                      fill: Colors.transparent,
                                    ),
                            ),
                          ),
                        ),
                      if (_dragMs != null)
                        Positioned(
                          left: left,
                          bottom: 26,
                          width: bubbleW,
                          child: _PreviewBubble(
                            preview: _preview,
                            time: _fmt(shownPos),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Seek-bar track that draws three layers like YouTube/Netflix: faint
/// background (unbuffered), a lighter "buffered" layer up to [buffered]
/// (fetched-ahead), and the accent played layer up to the thumb.
class _BufferedSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  _BufferedSliderTrackShape({
    required this.buffered,
    required this.bufferedColor,
    this.marks = const [],
  });

  /// Buffered fraction in [0, 1].
  final double buffered;
  final Color bufferedColor;

  /// Chapter/skip marker fractions in [0, 1] (AniSkip OP/ED boundaries),
  /// drawn as small notches poking above/below the track.
  final List<double> marks;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    final canvas = context.canvas;

    // 1. Background (unbuffered remainder).
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = sliderTheme.inactiveTrackColor ?? Colors.white24,
    );

    // 2. Buffered (fetched ahead).
    if (buffered > 0) {
      final bw = rect.width * buffered.clamp(0.0, 1.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left, rect.top, bw, rect.height),
          radius,
        ),
        Paint()..color = bufferedColor,
      );
    }

    // 3. Played (up to the thumb).
    final activeRight = thumbCenter.dx.clamp(rect.left, rect.right);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(rect.left, rect.top, activeRight, rect.bottom),
        radius,
      ),
      Paint()..color = sliderTheme.activeTrackColor ?? AppColors.accent,
    );

    // 4. Chapter / skip markers (AniSkip OP/ED boundaries) — small notches
    // that overhang the track so they read as markers, not part of the fill.
    if (marks.isNotEmpty) {
      final markPaint = Paint()..color = Colors.white.withValues(alpha: 0.95);
      final h = rect.height + 4;
      for (final m in marks) {
        final x = rect.left + rect.width * m.clamp(0.0, 1.0);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, rect.center.dy), width: 3, height: h),
            const Radius.circular(1.5),
          ),
          markPaint,
        );
      }
    }
  }
}

/// Floating thumbnail shown above the seek-bar thumb while scrubbing. Shows the
/// preview frame once one is available (never a loading spinner) with the
/// target time beneath it. Until a frame lands — or on sources that can't be
/// previewed — it's just a plain time bubble.
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.preview, required this.time});

  final SeekPreview? preview;
  final String time;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p != null)
          ValueListenableBuilder<Uint8List?>(
            valueListenable: p.frame,
            builder: (context, bytes, _) {
              if (bytes == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 168,
                    height: 94,
                    color: Colors.black,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              );
            },
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              time,
              style: AppText.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small bits.
// ─────────────────────────────────────────────────────────────────────────────

// Netflix-style "Skip intro/ending" pill — fades + slides up when it appears
// (it's mounted only while inside an AniSkip interval), with a ripple + a
// premium rounded look. A press-scale gives tactile feedback.
class _SkipButton extends StatefulWidget {
  const _SkipButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_SkipButton> createState() => _SkipButtonState();
}

class _SkipButtonState extends State<_SkipButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  )..forward();
  bool _pressed = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.45),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic)),
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: Material(
            color: Colors.black.withValues(alpha: 0.38),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.6),
                width: 1.2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                child: Text(
                  widget.label,
                  style: AppText.body.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// MegaSkip — Aniyomi-style manual "jump forward N seconds" pill. A compact,
// accent-outlined stadium that sits right-aligned just above the seek bar (so
// it never overlaps the bar or the controls), distinct from the AniSkip pill.
class _MegaSkipPill extends StatelessWidget {
  const _MegaSkipPill({required this.seconds, required this.onTap});
  final int seconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Deliberately the twin of the timestamp chip it now sits beside — same
    // fill, radius and type. The accent-outlined stadium it used to be was
    // louder than anything else on the bar and read as a stray element.
    // No tooltip: "+85s" already says what it does.
    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.keyboard_double_arrow_right_rounded,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 5),
              Text(
                '+${seconds}s',
                style: AppText.caption.copyWith(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  letterSpacing: 0.3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Small circular icon button (used for the unlock control while locked).
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.semanticLabel,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return _withTooltip(
      semanticLabel,
      Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
      ),
    );
  }
}

/// Long-press tooltip for the player's icon-only controls. Most of them lost
/// their text labels to keep the bars compact, so the tooltip is the only way
/// to find out what one does without pressing it.
///
/// Semantics are excluded by default because these buttons already declare
/// their own — letting the tooltip add a second label makes a screen reader
/// announce everything twice. Pass false for a control that has none.
Widget _withTooltip(
  String? message,
  Widget child, {
  bool excludeSemantics = true,
}) {
  if (message == null || message.isEmpty) return child;
  return Tooltip(
    message: message,
    excludeFromSemantics: excludeSemantics,
    child: child,
  );
}

/// Aspect-mode icon. The fit button dropped its text label to keep every
/// button the same width, so the icon has to carry which mode you're on.
IconData _fitIcon(String label) => switch (label) {
  'Fill' => Icons.crop_free_rounded,
  'Stretch' => Icons.open_in_full_rounded,
  _ => Icons.fit_screen_rounded,
};

/// One translucent capsule holding a set of [_BarButton]s. Grouping them means
/// a single soft backdrop behind the row instead of a chip per icon, which is
/// quieter over video — plain alpha, no BackdropFilter, so it costs nothing to
/// composite. It's also the Material the buttons' ripples paint onto; without
/// it they'd splash on the Scaffold underneath and be hidden by this backdrop.
class _BarGroup extends StatelessWidget {
  const _BarGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A single icon button inside a [_BarGroup] — uniform square footprint so the
/// row never reflows, transparent itself since the group carries the backdrop.
class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return _withTooltip(
      tooltip,
      Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}

/// A single leading-icon row in the ⋮ More overflow sheet.
class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // Tighter than the old 14 — the panel is narrower now, and these
            // rows were spaced like a settings screen rather than a menu.
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: [
                Icon(icon, color: AppColors.textPrimary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: AppText.body.copyWith(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Strips a leading episode marker from [title] when it just repeats [n].
///
/// Plenty of sources hand back "Episode 2: I Suppose You Aren't Aware", which
/// sits next to the "E2" the panel already draws and eats the whole line for
/// something you can see a centimetre to the left.
///
/// Two shapes, deliberately narrow:
///  * a word form — "Episode 2 …", "Ep.2 - …", "E2: …" — separator optional;
///  * a bare number — "2. …", "02 - …" — where the separator is REQUIRED,
///    otherwise a title like "12 Monkeys" on episode 12 would lose its name.
String stripEpisodePrefix(String title, int n) {
  final t = title.trim();
  final word = RegExp(
    '^(?:episode|ep\\.?|e)\\s*0*$n(?![0-9])\\s*[:\\-–—.)\\]]*\\s*',
    caseSensitive: false,
  );
  final bare = RegExp('^0*$n(?![0-9])\\s*[:\\-–—.)\\]]+\\s*');
  final m = word.firstMatch(t) ?? bare.firstMatch(t);
  if (m == null) return t;
  final rest = t.substring(m.end).trim();
  // Nothing but the marker — let the caller fall back to showing just "E2".
  return rest;
}

// One row in the panel — either a "SEASON n" header or an episode (with its
// global index into the flat episode list).
class _PanelItem {
  const _PanelItem.header(this.season) : index = -1;
  const _PanelItem.episode(this.index) : season = -1;
  final int season; // valid when index == -1
  final int index; // global episode index when season == -1
  bool get isHeader => index == -1;
}

// Right-side episodes panel (CloudStream-style): thumbnail + "E{n} · title"
// cards grouped by "SEASON n" headers for multi-season titles; the current one
// is highlighted and the list opens scrolled to it. Tap to switch.
class _EpisodesPanel extends StatefulWidget {
  const _EpisodesPanel({
    required this.episodes,
    required this.currentIndex,
    required this.cover,
    required this.coverHeaders,
    required this.onSelect,
  });

  final List<Episode> episodes;
  final int currentIndex;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final void Function(int) onSelect;

  @override
  State<_EpisodesPanel> createState() => _EpisodesPanelState();
}

class _EpisodesPanelState extends State<_EpisodesPanel> {
  /// Below this many episodes the search + sort row is more clutter than help,
  /// so it stays hidden and the list gets the space instead. Low enough that a
  /// normal season shows it — 20 meant a 13-episode series never did.
  static const int _toolsFrom = 8;
  static const double _headerH = 32;

  late final bool _multiSeason;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _desc = false; // newest-first
  bool _jumped = false; // the opening scroll-to-current has run
  int? _season; // season chip tapped; null = whichever holds the current episode

  // Everything is sized off the panel width rather than fixed px — a 104px
  // thumbnail in a box that can be 240 or 380 wide is what made this look
  // cramped on a small phone and lost on a tablet. Set in build().
  double _rowH = 64;
  double _thumbW = 88;

  @override
  void initState() {
    super.initState();
    _multiSeason = seasonsOf(widget.episodes).length > 1;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  bool _matches(Episode e, int i) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    final n = (e.number?.toInt() ?? (i + 1)).toString();
    return n == q || n.startsWith(q) || e.title.toLowerCase().contains(q);
  }

  List<_PanelItem> _buildItems() {
    final idx = [
      for (var i = 0; i < widget.episodes.length; i++)
        if (_matches(widget.episodes[i], i)) i,
    ];
    if (_desc) idx.sort((a, b) => b.compareTo(a));

    if (!_multiSeason) return [for (final i in idx) _PanelItem.episode(i)];

    final bySeason = <int, List<int>>{};
    for (final i in idx) {
      (bySeason[seasonOf(widget.episodes[i]) ?? 1] ??= []).add(i);
    }
    final seasons = bySeason.keys.toList()..sort();
    if (_desc) {
      final r = seasons.reversed.toList();
      seasons
        ..clear()
        ..addAll(r);
    }
    final out = <_PanelItem>[];
    for (final s in seasons) {
      out.add(_PanelItem.header(s));
      out.addAll(bySeason[s]!.map(_PanelItem.episode));
    }
    return out;
  }

  /// Exact pixel offset of the first item matching [test].
  ///
  /// The old version multiplied by a hardcoded 78px card height, so any row
  /// that was actually taller (a long two-line title) skewed the sum and the
  /// list opened further off the further in you were. Rows are a known fixed
  /// height now — titles clamp to one line — so this is exact rather than a
  /// guess.
  double _offsetOf(List<_PanelItem> items, bool Function(_PanelItem) test) {
    var o = 0.0;
    for (final it in items) {
      if (test(it)) return o;
      o += it.isHeader ? _headerH : _rowH;
    }
    return 0;
  }

  void _scrollTo(double target, {bool animate = false}) {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final to = target.clamp(0.0, max);
    if (animate) {
      _scroll.animateTo(
        to,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    // A flat share of the screen, floored and capped so it stays sane at both
    // extremes. The old 42%-with-a-300px-floor swallowed half a small screen
    // and left the same small thumbnails rattling around inside 480px on a
    // big one; the contents scale with this now, so the panel can stay
    // comparatively narrow and still read well.
    final panelW = (w * 0.33).clamp(250.0, 360.0);

    // Contents scale with the panel instead of sitting at fixed px inside it.
    final s = (panelW / 300).clamp(0.86, 1.16); // type scale
    final pad = (panelW * 0.045).clamp(11.0, 18.0);
    _thumbW = (panelW * 0.30).clamp(64.0, 116.0);
    final thumbH = _thumbW * 9 / 16;

    // Row height is the taller of the thumbnail and the text beside it, not
    // just the thumbnail. Uniform rows are what keep [_offsetOf] exact, so the
    // height can't simply grow per row — but the text DOES grow with the
    // system font-size setting, and at ~1.3x it needs more than the thumbnail
    // leaves, which would overflow the row. Measuring both and taking the
    // larger keeps rows uniform, the scroll maths exact, and nothing clipped.
    // At normal text scale the thumbnail wins, so this changes nothing.
    final ts = MediaQuery.textScalerOf(context);
    final textH =
        ts.scale(13.5 * s) * 1.15 + // E-number
        ts.scale(12.5 * s) * 1.2 + // title
        2 + // gap above the meta line
        ts.scale(11.5 * s) * 1.15; // runtime · date
    _rowH = (thumbH > textH ? thumbH : textH) + 14;

    final items = _buildItems();
    final showTools = widget.episodes.length >= _toolsFrom;
    final seasons = _multiSeason
        ? (items.where((i) => i.isHeader).map((i) => i.season).toList())
        : const <int>[];
    // Until you tap one, the highlighted chip is the season you're watching —
    // so opening the panel already tells you where you are.
    final selSeason =
        _season ?? seasonOf(widget.episodes[widget.currentIndex]) ?? 1;

    // Opening scroll, once, after the first layout — by then _rowH is known
    // and the list has clients, so the offset can be exact.
    if (!_jumped) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _jumped) return;
        _jumped = true;
        _scrollTo(
          _offsetOf(items, (it) => !it.isHeader && it.index == widget.currentIndex) -
              _rowH * 1.5,
        );
      });
    }

    return Material(
      color: Colors.transparent,
      child: FrostedSurface(
        blur: true,
        opacity: 0.88,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
        child: SizedBox(
          width: panelW,
          height: double.infinity,
          // Left inset dropped, right kept. This panel is pinned to the RIGHT
          // screen edge, so a display cutout on the left can never reach it —
          // but SafeArea reads the screen-wide insets and was padding ~30
          // logical px off the panel's inner left anyway, eating about 11% of
          // its width to dodge a notch that isn't on its side. Worse, the
          // amount was whatever that phone's cutout happened to be, so the
          // contents landed differently on every device. Right stays: rotate
          // the phone and the camera moves to that edge, where the panel
          // really does touch it.
          child: SafeArea(
            left: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(pad, 11, 4, 8),
                  child: Row(
                    children: [
                      Text(
                        'Episodes',
                        style: AppText.title.copyWith(fontSize: 17 * s),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${widget.episodes.length}',
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                            fontWeight: FontWeight.w700,
                            fontSize: 11.5 * s,
                          ),
                        ),
                      ),
                      // Season lives up here rather than in a row of its own.
                      // The panel is ~300px wide with a search row already at
                      // the top, so vertical space is the scarce thing — this
                      // costs none, which is a whole extra episode visible. It
                      // also can't break on an odd season count the way a
                      // fixed row of chips does.
                      if (seasons.length > 1)
                        PopupMenuButton<int>(
                          initialValue: selSeason,
                          tooltip: 'Season',
                          color: AppColors.surface2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(11),
                          ),
                          onSelected: (sn) {
                            setState(() => _season = sn);
                            _scrollTo(
                              _offsetOf(
                                items,
                                (it) => it.isHeader && it.season == sn,
                              ),
                              animate: true,
                            );
                          },
                          itemBuilder: (c) => [
                            for (final sn in seasons)
                              PopupMenuItem<int>(
                                value: sn,
                                height: 40,
                                child: Text(
                                  'Season $sn',
                                  style: AppText.caption.copyWith(
                                    color: sn == selSeason
                                        ? AppColors.accent
                                        : AppColors.textSecondary,
                                    fontWeight: sn == selSeason
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    fontSize: 12.5 * s,
                                  ),
                                ),
                              ),
                          ],
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.surface2,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(9, 4, 5, 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'S$selSeason',
                                    style: AppText.caption.copyWith(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12 * s,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.expand_more_rounded,
                                    size: 16,
                                    color: AppColors.textSecondary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppColors.textSecondary,
                        ),
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                if (showTools)
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 36,
                            child: TextField(
                              controller: _search,
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                              style: AppText.caption.copyWith(
                                color: AppColors.textPrimary,
                                fontSize: 12.5 * s,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Jump to episode…',
                                hintStyle: AppText.caption.copyWith(
                                  color: AppColors.textTertiary,
                                  fontSize: 12.5 * s,
                                ),
                                prefixIcon: const Icon(
                                  Icons.search_rounded,
                                  size: 17,
                                  color: AppColors.textTertiary,
                                ),
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                isDense: true,
                                filled: true,
                                fillColor: AppColors.surface2,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(9),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Newest-first / oldest-first.
                        Material(
                          color: AppColors.surface2,
                          borderRadius: BorderRadius.circular(9),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => setState(() => _desc = !_desc),
                            child: SizedBox(
                              width: 38,
                              height: 36,
                              child: Icon(
                                _desc
                                    ? Icons.arrow_downward_rounded
                                    : Icons.arrow_upward_rounded,
                                size: 17,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: EdgeInsets.all(pad),
                            child: Text(
                              'No episode matches “$_query”',
                              textAlign: TextAlign.center,
                              style: AppText.caption.copyWith(
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.only(bottom: 16),
                          itemCount: items.length,
                          itemBuilder: (c, k) {
                            final it = items[k];
                            if (it.isHeader) {
                              return SizedBox(
                                height: _headerH,
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(pad, 10, pad, 2),
                                  child: Text(
                                    'SEASON ${it.season}',
                                    style: AppText.caption.copyWith(
                                      color: AppColors.textTertiary,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                      fontSize: 11 * s,
                                    ),
                                  ),
                                ),
                              );
                            }
                            return _card(
                              widget.episodes[it.index],
                              it.index,
                              thumbH,
                              s,
                              pad,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One episode row. Fixed [_rowH] on purpose — uniform rows are what make
  /// [_offsetOf] exact, which is what fixes the opening scroll landing in the
  /// wrong place. That's also why the title clamps to one line.
  Widget _card(Episode e, int i, double thumbH, double s, double pad) {
    final cur = i == widget.currentIndex;
    final n = e.number?.toInt() ?? (i + 1);
    final raw = e.title.trim();
    final title = stripEpisodePrefix(_multiSeason ? cleanTitle(raw) : raw, n);
    final hasTitle = title.isNotEmpty;
    final thumb = (e.thumbnail != null && e.thumbnail!.isNotEmpty)
        ? e.thumbnail!
        : (widget.cover ?? '');

    // Runtime · air date, whichever the source actually gave us.
    final bits = <String>[
      if ((e.runtimeMinutes ?? 0) > 0) '${e.runtimeMinutes} min',
      if (cur) 'Now playing' else if ((e.date ?? '').trim().isNotEmpty)
        e.date!.trim(),
    ];

    return SizedBox(
      height: _rowH,
      child: Material(
        color: cur ? AppColors.accentSoft : Colors.transparent,
        child: InkWell(
          onTap: () => widget.onSelect(i),
          child: Stack(
            children: [
              // Accent rail on the current row — far clearer at a glance than
              // the coloured episode number alone.
              if (cur)
                Positioned(
                  left: 0,
                  top: 5,
                  bottom: 5,
                  width: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 7),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: SizedBox(
                        width: _thumbW,
                        height: thumbH,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            thumb.isNotEmpty
                                ? CachedNetworkImage(
                                    imageUrl: thumb,
                                    httpHeaders: widget.coverHeaders,
                                    fit: BoxFit.cover,
                                    memCacheWidth: 240,
                                    placeholder: (c, u) =>
                                        ColoredBox(color: AppColors.surface2),
                                    errorWidget: (c, u, e) =>
                                        ColoredBox(color: AppColors.surface2),
                                  )
                                : ColoredBox(color: AppColors.surface2),
                            if (cur)
                              DecoratedBox(
                                decoration: const BoxDecoration(
                                  color: Color(0x55000000),
                                ),
                                child: Center(
                                  child: Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 24 * s,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(width: 10 * s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'E$n',
                            style: AppText.body.copyWith(
                              color: cur
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5 * s,
                              height: 1.15,
                            ),
                          ),
                          if (hasTitle)
                            Text(
                              title,
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                                fontSize: 12.5 * s,
                                height: 1.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (bits.isNotEmpty || e.filler)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  if (e.filler) ...[
                                    const TagBadge(
                                      text: 'FILLER',
                                      color: AppColors.textTertiary,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Flexible(
                                    child: Text(
                                      bits.join(' · '),
                                      style: AppText.caption.copyWith(
                                        color: AppColors.textTertiary,
                                        fontSize: 11.5 * s,
                                        height: 1.15,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Netflix-style combined panel: Audio (left) | Subtitles (right), selections
// apply live without closing; a Sync section sits below.
class _AudioSubsSheet extends StatefulWidget {
  const _AudioSubsSheet({
    required this.controller,
    required this.onInteract,
    required this.onLoadFile,
    required this.onSearchOnline,
    required this.onTranslate,
  });
  final PlayerCubit controller;
  final VoidCallback onInteract;
  final VoidCallback onLoadFile;
  final VoidCallback onSearchOnline;
  final VoidCallback onTranslate;

  @override
  State<_AudioSubsSheet> createState() => _AudioSubsSheetState();
}

class _AudioSubsSheetState extends State<_AudioSubsSheet> {
  late String _category = widget.controller.activeCategory;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final h = MediaQuery.of(context).size.height;
    return StreamBuilder<Track>(
      stream: c.player.stream.track,
      builder: (context, snap) {
        final track = snap.data ?? c.player.state.track;
        final audioId = track.audio.id;
        final subId = track.subtitle.id;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: h * 0.5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _audioColumn(c, audioId)),
                      Container(
                        width: 0.5,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        color: AppColors.hairline,
                      ),
                      Expanded(child: _subColumn(c, subId)),
                    ],
                  ),
                ),
                const Divider(color: AppColors.hairline, height: 18),
                _DelayAdjuster(
                  label: 'Subtitle delay',
                  initial: c.subtitleDelay,
                  onChanged: (d) => c.setSubtitleDelay(d),
                  // Aniyomi-style two-tap auto-sync (subtitle only). Captures
                  // live on the controller so they survive closing the sheet.
                  sync: (
                    capture: c.captureSubSync,
                    clear: c.clearSubSync,
                    currentMs: () => c.subtitleDelay.inMilliseconds,
                    voiceOn: () => c.subSyncVoiceMs != null,
                    textOn: () => c.subSyncTextMs != null,
                  ),
                ),
                _DelayAdjuster(
                  label: 'Audio delay',
                  initial: c.audioDelay,
                  onChanged: (d) => c.setAudioDelay(d),
                ),
                _SheetRow(
                  label: 'Audio normalization',
                  subtitle:
                      'Evens out the volume — boosts quiet dialogue, '
                      'tames loud scenes',
                  active: sl<PlaybackPrefs>().audioNormalize,
                  onTap: () async {
                    await c.toggleAudioNormalize();
                    if (mounted) setState(() {});
                    widget.onInteract();
                  },
                ),
                _SheetRow(
                  label: 'Subtitle style',
                  icon: Icons.text_fields_rounded,
                  active: false,
                  onTap: () {
                    widget.onInteract();
                    openSubtitleStyleSheet(context, c, widget.onInteract);
                  },
                ),
                _SheetRow(
                  label: 'Styled subtitles (libass)',
                  subtitle: 'Real .ass styling — signs, karaoke. '
                      'Reopen episode to apply.',
                  toggleValue: c.styledSubtitlesOn,
                  active: false,
                  onTap: () {
                    c.toggleStyledSubtitles();
                    if (mounted) setState(() {});
                    widget.onInteract();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _audioColumn(PlayerCubit c, String audioId) {
    final cats = c.categories;
    final tracks = c.mediaAudioTracks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SheetSectionHeader('Audio'),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              if (cats.length > 1)
                for (final cat in cats)
                  _SheetRow(
                    label: cat.toUpperCase(),
                    active: _category == cat,
                    onTap: () {
                      c.switchCategory(cat);
                      setState(() => _category = cat);
                      widget.onInteract();
                    },
                  ),
              for (final t in tracks)
                _SheetRow(
                  label: t.language ?? t.title ?? t.id,
                  active: audioId == t.id,
                  onTap: () {
                    c.setAudioTrack(t);
                    widget.onInteract();
                  },
                ),
              if (cats.length <= 1 && tracks.length <= 1)
                _SheetRow(label: 'Default', active: true, onTap: () {}),
            ],
          ),
        ),
      ],
    );
  }

  Widget _subColumn(PlayerCubit c, String subId) {
    final embedded = c.mediaSubtitleTracks;
    final soft = c.softSubs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SheetSectionHeader('Subtitles'),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              _SheetRow(
                label: () {
                  final p = sl<PlaybackPrefs>().subtitlePreference;
                  final name = p.isEmpty
                      ? 'Auto'
                      : (p == 'off' ? 'Off' : (languageByPref(p)?.name ?? p.toUpperCase()));
                  return 'Preferred language: $name';
                }(),
                icon: Icons.language_rounded,
                active: false,
                onTap: () async {
                  final picked = await showSubtitleLanguagePicker(
                    context, sl<PlaybackPrefs>().subtitlePreference);
                  if (picked == null) return;
                  await sl<PlaybackPrefs>().setSubtitlePreference(picked);
                  c.reapplyPreferredSubtitle();
                  widget.onInteract();
                },
              ),
              _SheetRow(
                label: 'Off',
                active: subId == 'no',
                onTap: () {
                  c.subtitlesOff();
                  widget.onInteract();
                },
              ),
              for (final t in embedded)
                _SheetRow(
                  label: t.title ?? t.language ?? t.id,
                  active: subId == t.id,
                  onTap: () {
                    c.setSubtitle(t);
                    widget.onInteract();
                  },
                ),
              for (final s in soft)
                _SheetRow(
                  label: s.label ?? s.lang,
                  // A URI soft-sub is applied via SubtitleTrack.uri(s.url), whose
                  // media_kit track id IS the url — so the active one highlights.
                  active: subId == s.url,
                  onTap: () {
                    c.setSoftSub(s);
                    widget.onInteract();
                  },
                ),
              _SheetRow(
                label: 'Search subtitles online',
                icon: Icons.search_rounded,
                active: false,
                onTap: widget.onSearchOnline,
              ),
              _SheetRow(
                label: 'Load from file…',
                icon: Icons.upload_file,
                active: false,
                onTap: widget.onLoadFile,
              ),
              if (c.softSubs.isNotEmpty || c.canTranslateSub)
                _SheetRow(
                  label: 'Translate subtitles…',
                  icon: Icons.translate_rounded,
                  active: false,
                  onTap: widget.onTranslate,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Online subtitle search (OpenSubtitles). A query field (prefilled with the
/// show title) + a results list; tapping a result downloads it and calls
/// [onApply] with the local file path. Surfaces a loading state and readable
/// errors (including the "add an API key" hint when no key is set).
class _OnlineSubtitleSheet extends StatefulWidget {
  const _OnlineSubtitleSheet({
    required this.initialQuery,
    required this.onApply,
    this.initialLanguage = '',
    this.imdbId,
    this.tmdbId,
  });
  final String initialQuery;
  final Future<void> Function(String localPath) onApply;

  /// ISO-639-1 code pre-selected in the language picker ('' = any language).
  final String initialLanguage;

  /// When non-null, passed to [SubtitleSearchService.search] for higher
  /// accuracy (OpenSubtitles can search by IMDb/TMDB id in addition to title).
  final String? imdbId;
  final int? tmdbId;

  @override
  State<_OnlineSubtitleSheet> createState() => _OnlineSubtitleSheetState();
}

class _OnlineSubtitleSheetState extends State<_OnlineSubtitleSheet> {
  final _service = SubtitleSearchService();
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );

  /// ISO-639-1 code for the selected search language, or '' = any language.
  late String _selectedLang = widget.initialLanguage;

  bool _searching = false;
  bool _downloading = false;
  String? _error;
  List<SubtitleSearchResult> _results = const [];

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _results = const [];
    });
    try {
      final results = await _service.search(
        q,
        language: _selectedLang.isEmpty ? '' : _selectedLang,
        imdbId: widget.imdbId,
        tmdbId: widget.tmdbId,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        if (results.isEmpty) _error = 'No subtitles found for “$q”.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = e is SubtitleSearchException ? e.message : 'Search failed: $e';
      });
    }
  }

  Future<void> _pick(SubtitleSearchResult r) async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final path = await _service.download(r);
      if (!mounted) return;
      await widget.onApply(path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e is SubtitleSearchException
            ? e.message
            : 'Download failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 10 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text('Search subtitles online', style: AppText.headline),
          ),
          // Language picker — defaults to the user's preferred subtitle
          // language (when set in Settings) and lets the user change it
          // per-search without leaving the sheet.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Row(
              children: [
                Text(
                  'Language:',
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _selectedLang.isEmpty ? '' : _selectedLang,
                  dropdownColor: AppColors.surface2,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(
                        'Any',
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    for (final lang in kSubtitleLanguages)
                      DropdownMenuItem(
                        value: lang.iso1,
                        child: Text(
                          lang.name,
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedLang = v);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextField(
              controller: _query,
              autofocus: widget.initialQuery.trim().isEmpty,
              textInputAction: TextInputAction.search,
              cursorColor: AppColors.accent,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Movie or show title',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                  tooltip: 'Search',
                  onPressed: _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: h * 0.42),
            child: _body(),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_searching) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }
    if (_error != null && _results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
        child: Center(
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return Stack(
      children: [
        ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                child: Text(
                  _error!,
                  style: AppText.caption.copyWith(color: AppColors.accent),
                ),
              ),
            for (final r in _results)
              _SheetRow(
                label: r.language.isNotEmpty
                    ? '[${r.language.toUpperCase()}] ${r.name}'
                    : r.name,
                active: false,
                onTap: () => _pick(r),
              ),
          ],
        ),
        if (_downloading)
          Positioned.fill(
            child: ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Opens the Subtitle-style sheet (font / colour / background / position /
/// size). Lives over whatever opened it; changes apply live via the controller.
/// Opens the shared Subtitle-style sheet (live preview + all controls). Pass a
/// [controller] from the player so changes apply to the video live; pass null
/// from Settings, where there's no active player and it just persists prefs.
void openSubtitleStyleSheet(
  BuildContext context,
  PlayerCubit? controller,
  VoidCallback onInteract,
) {
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
        child: _SubtitleStyleSheet(
          controller: controller,
          onInteract: onInteract,
        ),
      ),
    ),
  );
}

/// Live subtitle styling: bundled-font picker, text colour swatches, a
/// background-opacity slider, a vertical-position slider, and size. Each change
/// persists to [PlaybackPrefs] and re-applies via [PlayerCubit.applySubtitleStyle].
class _SubtitleStyleSheet extends StatefulWidget {
  const _SubtitleStyleSheet({
    required this.controller,
    required this.onInteract,
  });
  final PlayerCubit? controller;
  final VoidCallback onInteract;

  @override
  State<_SubtitleStyleSheet> createState() => _SubtitleStyleSheetState();
}

class _SubtitleStyleSheetState extends State<_SubtitleStyleSheet> {
  PlaybackPrefs get _prefs => sl<PlaybackPrefs>();

  /// Which fonts are usable now (Default/bundled/downloaded). A font that isn't
  /// downloaded yet is fetched on tap. Populated in [initState].
  final Map<String, bool> _fontAvailable = {};

  /// Fonts currently downloading — their row shows a spinner.
  final Set<String> _downloading = {};

  @override
  void initState() {
    super.initState();
    () async {
      for (final f in kBundledSubtitleFonts) {
        if (f.isEmpty) continue;
        _fontAvailable[f] = await SubtitleFontService.instance.isAvailable(f);
      }
      if (mounted) setState(() {});
    }();
  }

  /// Apply a font — downloading it first (with a spinner on its row) if it
  /// isn't cached yet.
  Future<void> _pickFont(String f) async {
    if (f.isNotEmpty && !(_fontAvailable[f] ?? true)) {
      if (_downloading.contains(f)) return; // already fetching
      setState(() => _downloading.add(f));
      final ok = await SubtitleFontService.instance.ensure(f);
      if (!mounted) return;
      setState(() {
        _downloading.remove(f);
        _fontAvailable[f] = ok;
      });
      if (!ok) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text("Couldn't download $f")),
        );
        return;
      }
    }
    await _apply(() => _prefs.setSubtitleFont(f));
  }

  // Text-colour swatches, stored as #RRGGBBAA (opaque).
  static const List<(String, String)> _colors = [
    ('#FFFFFFFF', 'White'),
    ('#FFFF00FF', 'Yellow'),
    ('#00E5FFFF', 'Cyan'),
    ('#7CFC00FF', 'Green'),
    ('#FF6B6BFF', 'Red'),
    ('#000000FF', 'Black'),
  ];


  Future<void> _apply(Future<void> Function() mutate) async {
    await mutate();
    await widget.controller?.applySubtitleStyle();
    if (mounted) setState(() {});
    widget.onInteract();
  }

  /// Reset every subtitle-style pref to its default value.
  Future<void> _resetToDefault() => _apply(() async {
        await _prefs.setSubtitleFont('');
        await _prefs.setSubtitleColorHex('#FFFFFFFF');
        await _prefs.setSubtitleTextOpacity(1.0);
        await _prefs.setSubtitleOutlineType('soft');
        await _prefs.setSubtitleOutlineColorHex('#000000FF');
        await _prefs.setSubtitleOutlineWidth(2.0);
        await _prefs.setSubtitleBgOpacity(0.0);
        await _prefs.setSubtitlePosition(95);
        await _prefs.setSubtitleScale(1.0);
      });

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final font = _prefs.subtitleFont;
    final colorHex = _prefs.subtitleColorHex.toUpperCase();
    final size = _prefs.subtitleScale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text('Subtitle style', style: AppText.headline),
          ),
          // Live WYSIWYG preview — built with the SAME buildSubtitleTextStyle as
          // the real overlay, so what you see here is what renders on the video.
          Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            height: 92,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF33405E), Color(0xFF0E121B)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'The quick brown fox',
                textAlign: TextAlign.center,
                style: buildSubtitleTextStyle(_prefs, fontSize: 22.0 * size),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                const _SheetSectionHeader('Font'),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: h * 0.28),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final f in kBundledSubtitleFonts)
                        _SheetRow(
                          label: f.isEmpty ? 'Default' : f,
                          subtitle: _downloading.contains(f)
                              ? 'Downloading…'
                              : ((_fontAvailable[f] ?? true)
                                    ? null
                                    : 'Tap to download'),
                          loading: _downloading.contains(f),
                          active: font == f,
                          onTap: () => _pickFont(f),
                        ),
                    ],
                  ),
                ),
                const _SheetSectionHeader('Text colour'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final (hex, name) in _colors)
                        _ColorSwatch(
                          color: _colorFromHex(hex),
                          label: name,
                          active: colorHex == hex,
                          onTap: () =>
                              _apply(() => _prefs.setSubtitleColorHex(hex)),
                        ),
                    ],
                  ),
                ),
                const _SheetSectionHeader('Text opacity'),
                _SliderRow(
                  value: _prefs.subtitleTextOpacity,
                  min: 0.1,
                  max: 1,
                  divisions: 9,
                  label: '${(_prefs.subtitleTextOpacity * 100).round()}%',
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitleTextOpacity(v)),
                ),
                const _SheetSectionHeader('Outline style'),
                for (final (id, name) in kSubtitleOutlineTypes)
                  _SheetRow(
                    label: name,
                    active: _prefs.subtitleOutlineType == id,
                    onTap: () =>
                        _apply(() => _prefs.setSubtitleOutlineType(id)),
                  ),
                const _SheetSectionHeader('Outline colour'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final (hex, name) in _colors)
                        _ColorSwatch(
                          color: _colorFromHex(hex),
                          label: name,
                          active:
                              _prefs.subtitleOutlineColorHex.toUpperCase() == hex,
                          onTap: () => _apply(
                            () => _prefs.setSubtitleOutlineColorHex(hex),
                          ),
                        ),
                    ],
                  ),
                ),
                const _SheetSectionHeader('Outline width'),
                _SliderRow(
                  value: _prefs.subtitleOutlineWidth,
                  min: 0,
                  max: 8,
                  divisions: 16,
                  label: _prefs.subtitleOutlineWidth.toStringAsFixed(1),
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitleOutlineWidth(v)),
                ),
                const _SheetSectionHeader('Background'),
                _SliderRow(
                  value: _prefs.subtitleBgOpacity,
                  min: 0,
                  max: 1,
                  divisions: 10,
                  label: '${(_prefs.subtitleBgOpacity * 100).round()}%',
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitleBgOpacity(v)),
                ),
                const _SheetSectionHeader('Position'),
                _SliderRow(
                  value: _prefs.subtitlePosition.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: _prefs.subtitlePosition >= 50 ? 'Bottom' : 'Top',
                  onChanged: (v) =>
                      _apply(() => _prefs.setSubtitlePosition(v.round())),
                ),
                const _SheetSectionHeader('Size'),
                _SliderRow(
                  value: size.clamp(0.6, 2.0),
                  min: 0.6,
                  max: 2.0,
                  divisions: 14,
                  label: '${(size * 100).round()}%',
                  onChanged: (v) => _apply(() => _prefs.setSubtitleScale(v)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: OutlinedButton.icon(
                    onPressed: _resetToDefault,
                    icon: const Icon(Icons.restart_alt_rounded, size: 19),
                    label: const Text('Reset to default'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: BorderSide(color: AppColors.hairline),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _colorFromHex(String hex) {
    // Stored as #RRGGBBAA → Flutter wants 0xAARRGGBB.
    final h = hex.replaceFirst('#', '');
    if (h.length != 8) return Colors.white;
    final rgb = h.substring(0, 6);
    final a = h.substring(6, 8);
    return Color(int.parse('$a$rgb', radix: 16));
  }
}

/// A circular colour swatch with a label, accent-ringed when active.
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final Color color;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? AppColors.accent : AppColors.hairline,
              width: active ? 3 : 1,
            ),
          ),
          child: active
              ? Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: color.computeLuminance() > 0.5
                      ? Colors.black
                      : Colors.white,
                )
              : null,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: AppText.caption.copyWith(
            color: active ? AppColors.accent : AppColors.textSecondary,
          ),
        ),
      ],
    );
    // TV: GestureDetector isn't D-pad focusable, so colours can't be selected.
    // Wrap in TvFocusable (OK selects, shows a focus ring). Mobile keeps the tap.
    if (sl<AppMode>().isTv) {
      return TvFocusable(onTap: onTap, child: content);
    }
    return GestureDetector(onTap: onTap, child: content);
  }
}

/// A labelled slider row used inside the Subtitle-style sheet.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    // On TV a focused Slider swallows D-pad ↑/↓ (you can't move off it). Swap in
    // a focusable ◄ value ► stepper: ◄/► adjust, ↑/↓ move to the next control.
    if (sl<AppMode>().isTv) {
      final step = (max - min) / divisions;
      return _TvStepperRow(
        label: label,
        onDec: value <= min ? null : () => onChanged((value - step).clamp(min, max)),
        onInc: value >= max ? null : () => onChanged((value + step).clamp(min, max)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accent,
                thumbColor: AppColors.accent,
                inactiveTrackColor: AppColors.surface2,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TV replacement for [_SliderRow]'s slider: one full-width focusable row so
/// D-pad ▲/▼ reliably land on it (edge buttons get skipped by directional
/// focus, and a Slider would trap ▲/▼). When focused (accent ring), ◀ decreases
/// and ▶ increases; ▲/▼/OK pass through to move to the next control.
class _TvStepperRow extends StatefulWidget {
  const _TvStepperRow({required this.label, this.onDec, this.onInc});
  final String label;
  final VoidCallback? onDec;
  final VoidCallback? onInc;
  @override
  State<_TvStepperRow> createState() => _TvStepperRowState();
}

class _TvStepperRowState extends State<_TvStepperRow> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onDec?.call();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onInc?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // ▲/▼/OK propagate → focus traversal
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: _focused
              ? AppColors.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          border: Border.all(
            color: _focused ? AppColors.accent : AppColors.surface2,
            width: _focused ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.chevron_left,
                color: widget.onDec == null
                    ? AppColors.textTertiary
                    : AppColors.accent),
            Expanded(
              child: Text(
                widget.label,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Icon(Icons.chevron_right,
                color: widget.onInc == null
                    ? AppColors.textTertiary
                    : AppColors.accent),
          ],
        ),
      ),
    );
  }
}

/// Play/pause button whose icon MORPHS between play and pause (Dantotsu/YouTube
/// style) instead of a hard swap. Driven by [playing]; sits in a soft ringed
/// circle. Pure UI — [onTap] is the same togglePlay call as before.
/// Soft, rounded play/pause (reDantotsu-style) — the stock [AnimatedIcons]
/// morph uses sharp, blocky shapes; the `_rounded` variants have the pill
/// corners we want. Cross-fades + gently scales between the two on toggle.
class _AnimatedPlayPause extends StatelessWidget {
  const _AnimatedPlayPause({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // No tooltip — play/pause needs no explaining, and a bubble over the
    // middle of the picture is just in the way.
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      // Larger disc than the episode arrows so the row keeps its hierarchy —
      // the icon inside is bigger too, so matching discs would have crowded
      // this one while leaving the arrows swimming in theirs.
      child: _TransportDisc(
        size: 58,
        onTap: onTap,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.72, end: 1).animate(anim),
              child: child,
            ),
          ),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey<bool>(playing),
            color: Colors.white,
            size: 34,
          ),
        ),
      ),
    );
  }
}

/// Backdrop for the three centre transport buttons. They sit over the middle
/// of the picture where barely any scrim reaches, so they carry more alpha
/// than the bottom capsules' 0.3 — at that level they wash out on a bright
/// frame. [dimmed] fades the disc along with its icon, otherwise a dead arrow
/// ends up inside a solid circle and reads as broken rather than unavailable.
class _TransportDisc extends StatelessWidget {
  const _TransportDisc({
    required this.size,
    required this.child,
    required this.onTap,
    this.dimmed = false,
  });

  final double size;
  final Widget child;
  final VoidCallback? onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    // The disc is itself the Material the ripple paints onto. A plain
    // DecoratedBox wouldn't do: ink splashes render on the nearest Material
    // ancestor, which would be the Scaffold underneath — so the ripple would
    // spread behind this circle and never be seen. Clipping to the same
    // CircleBorder keeps the splash inside the disc instead of squaring off.
    return Material(
      color: Colors.black.withValues(alpha: dimmed ? 0.18 : 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        // Explicit, because the theme's default splash is tuned for opaque
        // surfaces and barely shows on a translucent black disc over video.
        splashColor: Colors.white.withValues(alpha: 0.22),
        highlightColor: Colors.white.withValues(alpha: 0.10),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// Episode step either side of play/pause. A null [onTap] means there's
/// nowhere to step (first or last episode): the button dims and stops taking
/// touches, so the tap falls through and toggles the controls like any other
/// empty patch of screen rather than dying on a dead button. It stays mounted
/// either way, which is what keeps play/pause centred instead of sliding as
/// the row shrinks.
///
/// No tooltip: the three transport controls are the most self-evident thing on
/// the screen, so a bubble over them is noise. The bottom bar keeps its
/// tooltips — those buttons lost their text labels and need the help.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: IgnorePointer(
        ignoring: !enabled,
        child: _TransportDisc(
          size: 46,
          dimmed: !enabled,
          onTap: onTap,
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: enabled ? 1 : 0.28),
            size: 26,
          ),
        ),
      ),
    );
  }
}

/// The player's bottom-sheet surface: a SOLID, detached card that floats above
/// the screen edges (margins + full-radius + soft shadow), centred in landscape
/// — instead of an edge-to-edge frosted panel. Drop-in for the old
/// `FrostedSurface(...)` sheet wrappers: it accepts (and ignores) blur/opacity/
/// borderRadius so those call sites only needed a rename.
class _SheetSurface extends StatelessWidget {
  const _SheetSurface({
    bool blur = true,
    double opacity = 0.75,
    BorderRadius? borderRadius,
    required this.child,
  });
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(24);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        10,
        0,
        10,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: r,
                  border: Border.all(color: AppColors.hairline),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 40,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: ClipRRect(borderRadius: r, child: child),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour-adjustment sheet: quick-preset chips + individual sliders for mpv's
/// video equalizer (brightness/contrast/saturation/gamma/hue, -100..100). Live
/// preview on drag; persists on release.
class _ColorSheet extends StatefulWidget {
  const _ColorSheet({required this.controller, required this.onInteract});
  final PlayerCubit controller;
  final VoidCallback onInteract;
  @override
  State<_ColorSheet> createState() => _ColorSheetState();
}

class _ColorSheetState extends State<_ColorSheet> {
  late int _b, _c, _s, _g, _h;

  static const _quick = [
    'natural',
    'anime',
    'anime_vibrant',
    'vivid',
    'cinema',
    'grayscale',
  ];

  @override
  void initState() {
    super.initState();
    final p = sl<PlaybackPrefs>();
    _b = p.colorBrightness;
    _c = p.colorContrast;
    _s = p.colorSaturation;
    _g = p.colorGamma;
    _h = p.colorHue;
  }

  void _applyPreset(ColorProfile prof) {
    widget.controller.applyColorPreset(prof);
    setState(() {
      _b = prof.brightness;
      _c = prof.contrast;
      _s = prof.saturation;
      _g = prof.gamma;
      _h = prof.hue;
    });
    widget.onInteract();
  }

  Widget _slider(String label, String prop, int value, ValueChanged<int> set) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: AppText.body),
              Text(
                value > 0 ? '+$value' : '$value',
                style: AppText.body.copyWith(
                  color: value == 0 ? AppColors.textTertiary : AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              thumbColor: AppColors.accent,
              inactiveTrackColor: AppColors.textSecondary.withValues(alpha: 0.3),
              overlayColor: AppColors.accent.withValues(alpha: 0.2),
            ),
            child: Slider(
              min: -100,
              max: 100,
              divisions: 200,
              value: value.toDouble(),
              label: '$value',
              onChanged: (v) {
                set(v.round());
                widget.controller.previewColor(prop, v.round());
              },
              onChangeEnd: (v) => widget.controller.setColor(prop, v.round()),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const SizedBox(width: 36, height: 4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Colour', style: AppText.headline),
              TextButton(
                onPressed: () {
                  widget.controller.resetColor();
                  setState(() => _b = _c = _s = _g = _h = 0);
                  widget.onInteract();
                },
                child: const Text('Reset'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final id in _quick)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _applyPreset(ColorProfiles.byId(id)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        ColorProfiles.byId(id).label,
                        style: AppText.body,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            children: [
              _slider('Brightness', 'brightness', _b, (v) => setState(() => _b = v)),
              _slider('Contrast', 'contrast', _c, (v) => setState(() => _c = v)),
              _slider('Saturation', 'saturation', _s, (v) => setState(() => _s = v)),
              _slider('Gamma', 'gamma', _g, (v) => setState(() => _g = v)),
              _slider('Hue', 'hue', _h, (v) => setState(() => _h = v)),
            ],
          ),
        ),
      ],
    );
  }
}

/// A sheet whose options are one wrapping row of chips rather than a vertical
/// list. For short lists of short values — the kind where a full-height list
/// costs the whole screen for six words. Same grab handle and header as
/// [_SheetColumn] so the two read as the same family.
class _SheetChips extends StatelessWidget {
  const _SheetChips({
    required this.header,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final String header;
  final List<String> labels;
  final int selected; // -1 = nothing matches
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const SizedBox(width: 36, height: 4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Text(header, style: AppText.headline),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < labels.length; i++)
                Material(
                  color: i == selected
                      ? AppColors.accent
                      : Colors.transparent,
                  shape: StadiumBorder(
                    side: i == selected
                        ? BorderSide.none
                        : BorderSide(
                            color: Colors.white.withValues(alpha: 0.16),
                          ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelect(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text(
                        labels[i],
                        style: AppText.body.copyWith(
                          color: i == selected
                              ? Colors.white
                              : AppColors.textSecondary,
                          fontWeight: i == selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SheetColumn extends StatelessWidget {
  const _SheetColumn({required this.header, required this.children});
  final String header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const SizedBox(width: 36, height: 4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(header, style: AppText.headline),
        ),
        // Cap the list height so a long sheet (e.g. the ~25-language translate
        // list) scrolls instead of overflowing and clipping at whatever fits.
        // Short sheets are shorter than the cap, so shrinkWrap still sizes them
        // to their content and they look/behave exactly as before.
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: ListView(shrinkWrap: true, children: children),
          ),
        ),
      ],
    );
  }
}

/// Source-picker row label: the provider's per-source name with its resolution
/// appended (e.g. "MovieBox (Hindi Audio) · 1080p"), so the quality shows even
/// when the source carries its own name. Skips a non-resolution quality
/// ("auto"/empty) and never doubles up a resolution the name already contains.
String _sourceLabelWithQuality(String label, String? quality) {
  final q = (quality ?? '').trim();
  if (q.isEmpty || q.toLowerCase() == 'auto') return label;
  if (label.toLowerCase().contains(q.toLowerCase())) return label;
  return '$label · $q';
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.toggleValue,
    this.loading = false,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  /// Optional trailing icon (e.g. upload for "Load from file…").
  final IconData? icon;

  /// Optional secondary line under the label — explains what a setting does
  /// (e.g. for jargon like "Audio normalization") so it's self-describing.
  final String? subtitle;

  /// When non-null, the row is a toggle: renders a trailing Switch reflecting
  /// this value (instead of the icon/check), and stays plain (no accent tint).
  final bool? toggleValue;

  /// Show a trailing spinner (e.g. while a font downloads).
  final bool loading;

  @override
  Widget build(BuildContext context) {
    // Netflix-style: the selected row is tinted + accent-bold with a trailing
    // check; others are plain.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: toggleValue == null && active
            ? AppColors.accentSoft
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: AppText.body.copyWith(
                          color: toggleValue == null && active
                              ? AppColors.accent
                              : AppColors.textPrimary,
                          fontWeight: toggleValue == null && active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (loading)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  )
                else if (toggleValue != null)
                  Switch.adaptive(
                    value: toggleValue!,
                    onChanged: (_) => onTap(),
                    activeThumbColor: AppColors.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )
                else if (icon != null)
                  Icon(icon, color: AppColors.textSecondary, size: 20)
                else if (active)
                  Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.accent,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A −/value/+ stepper for a sync delay (subtitle or audio), in 0.25s steps.
/// Holds its own value so the sheet updates live.
class _DelayAdjuster extends StatefulWidget {
  const _DelayAdjuster({
    required this.label,
    required this.initial,
    required this.onChanged,
    this.sync,
  });
  final String label;
  final Duration initial;
  final ValueChanged<Duration> onChanged;

  /// When set, shows the Aniyomi-style two-tap auto-sync below the stepper.
  /// [capture] records a tap (voice/text) and returns the applied delta (ms)
  /// once both are set; [currentMs] reads the resulting delay; [voiceOn]/
  /// [textOn] report which point is currently captured (for the highlight).
  final ({
    int? Function(bool voice) capture,
    void Function() clear,
    int Function() currentMs,
    bool Function() voiceOn,
    bool Function() textOn,
  })?
  sync;

  @override
  State<_DelayAdjuster> createState() => _DelayAdjusterState();
}

class _DelayAdjusterState extends State<_DelayAdjuster> {
  late int _ms = widget.initial.inMilliseconds;
  static const int _step = 250;

  // The two-tap captures themselves live on the controller (via [widget.sync])
  // so they survive closing the sheet; here we only hold the transient note.
  String? _note;
  Timer? _noteTimer;

  @override
  void dispose() {
    _noteTimer?.cancel();
    super.dispose();
  }

  void _bump(int delta) {
    setState(() => _ms = (_ms + delta).clamp(-30000, 30000));
    widget.onChanged(Duration(milliseconds: _ms));
  }

  void _capture(bool voice) {
    final delta = widget.sync!.capture(voice);
    if (delta != null) {
      // Both points captured → the controller applied the offset; mirror it.
      setState(() => _ms = widget.sync!.currentMs().clamp(-30000, 30000));
      final s = (delta / 1000).toStringAsFixed(2);
      _flashNote('Aligned ${delta >= 0 ? '+' : ''}${s}s');
    } else {
      setState(() {}); // reflect the single-capture highlight
    }
  }

  void _flashNote(String msg) {
    _noteTimer?.cancel();
    setState(() => _note = msg);
    _noteTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _note = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final secs = (_ms / 1000).toStringAsFixed(2);
    final shown = _ms > 0 ? '+${secs}s' : '${secs}s';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                ),
              ),
              _stepBtn(
                Icons.remove_rounded,
                () => _bump(-_step),
                semanticLabel: 'Decrease ${widget.label.toLowerCase()}',
              ),
              SizedBox(
                width: 72,
                child: Text(
                  shown,
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(
                    color: _ms == 0 ? AppColors.textSecondary : AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _stepBtn(
                Icons.add_rounded,
                () => _bump(_step),
                semanticLabel: 'Increase ${widget.label.toLowerCase()}',
              ),
              IconButton(
                tooltip: 'Reset',
                icon: const Icon(
                  Icons.restart_alt_rounded,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
                onPressed: _ms == 0 ? null : () => _bump(-_ms),
              ),
            ],
          ),
        ),
        if (widget.sync != null) _syncSection(),
      ],
    );
  }

  Widget _syncSection() {
    final s = widget.sync!;
    final voiceOn = s.voiceOn();
    final textOn = s.textOn();
    // Progress-aware hint so it's obvious what to do next (and that a capture
    // is still pending after you reopen the sheet).
    final hint = _note ??
        (voiceOn
            ? 'Voice captured ✓ — play until the subtitle shows, then tap '
                  'Subtitle seen. (You can close this sheet meanwhile.)'
            : textOn
            ? 'Subtitle captured ✓ — now tap Voice heard when you hear the line.'
            : 'Auto-sync: tap when you HEAR a line, then when its SUBTITLE '
                  'appears.');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  hint,
                  style: AppText.caption.copyWith(
                    color: (_note != null || voiceOn || textOn)
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                ),
              ),
              // Cancel a pending capture without applying anything.
              if (voiceOn || textOn)
                InkWell(
                  onTap: () {
                    s.clear();
                    _noteTimer?.cancel();
                    setState(() => _note = null);
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      'Clear',
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _syncBtn(
                  'Voice heard',
                  Icons.hearing_rounded,
                  voiceOn,
                  () => _capture(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _syncBtn(
                  'Subtitle seen',
                  Icons.subtitles_rounded,
                  textOn,
                  () => _capture(false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _syncBtn(String label, IconData icon, bool done, VoidCallback onTap) {
    return Material(
      color: done
          ? AppColors.accent.withValues(alpha: 0.18)
          : AppColors.surface2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: done ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: done ? AppColors.accent : AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepBtn(
    IconData icon,
    VoidCallback onTap, {
    String? semanticLabel,
  }) => Semantics(
    button: true,
    label: semanticLabel,
    child: Material(
      color: AppColors.surface2,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: AppColors.textPrimary, size: 20),
        ),
      ),
    ),
  );
}

/// "Stats for nerds" info panel — shows the user-selected [fields] (keys from
/// [kPlayerInfoFields]) in a translucent top-left card, refreshed ~1×/sec.
/// Read-only; auto-shown with the controls.
class _InfoOverlay extends StatefulWidget {
  const _InfoOverlay({required this.controller, required this.fields});
  final PlayerCubit controller;
  final List<String> fields;

  @override
  State<_InfoOverlay> createState() => _InfoOverlayState();
}

class _InfoOverlayState extends State<_InfoOverlay> {
  Map<String, String> _values = const {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final c = widget.controller;
    final st = c.player.state;
    final out = <String, String>{};
    for (final key in widget.fields) {
      switch (key) {
        case 'resolution':
          final w = st.width ?? 0, h = st.height ?? 0;
          out[key] = (w > 0 && h > 0) ? '$w×$h' : '—';
        case 'source':
          final l = c.state.active?.label?.trim();
          out[key] = (l != null && l.isNotEmpty) ? l : '—';
        case 'quality':
          out[key] =
              c.activeSourceQuality ?? c.state.active?.quality ?? 'auto';
        case 'buffer':
          out[key] = '${st.buffer.inSeconds}s';
        case 'decoder':
          out[key] = _decoderLabel(sl<PlaybackPrefs>().videoDecoder);
        case 'speed':
          out[key] = '${st.rate}×';
        case 'atrack':
          out[key] = _trackLabel(st.track.audio.id, st.track.audio.title,
              st.track.audio.language);
        case 'strack':
          out[key] = _trackLabel(st.track.subtitle.id, st.track.subtitle.title,
              st.track.subtitle.language);
        case 'vcodec':
          out[key] = await c.mpvStat('video-codec') ?? '—';
        case 'acodec':
          out[key] = await c.mpvStat('audio-codec') ?? '—';
        case 'fps':
          final f = await c.mpvStat('estimated-vf-fps');
          out[key] =
              f == null ? '—' : (double.tryParse(f)?.toStringAsFixed(2) ?? f);
        case 'vbitrate':
          out[key] = _bitrate(await c.mpvStat('video-bitrate'));
        case 'dropped':
          out[key] = await c.mpvStat('frame-drop-count') ?? '0';
        case 'af':
          // Live mpv softvol level (the real applied gain), e.g. "200%".
          final v = await c.mpvStat('volume');
          final n = double.tryParse(v ?? '');
          out[key] = n == null ? '—' : '${n.round()}%';
      }
    }
    if (mounted) setState(() => _values = out);
  }

  String _decoderLabel(String mode) => switch (mode) {
    'direct' => 'Hardware',
    'sw' => 'Software',
    'auto' => 'Auto',
    _ => 'Hardware+', // copy
  };

  String _trackLabel(String id, String? title, String? language) {
    if (id == 'no') return 'Off';
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    final l = language?.trim();
    if (l != null && l.isNotEmpty) return l;
    return id;
  }

  String _bitrate(String? bps) {
    final v = int.tryParse(bps ?? '');
    if (v == null || v <= 0) return '—';
    return v >= 1000000
        ? '${(v / 1000000).toStringAsFixed(1)} Mbps'
        : '${(v / 1000).round()} kbps';
  }

  @override
  Widget build(BuildContext context) {
    final labels = {for (final f in kPlayerInfoFields) f.$1: f.$2};
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final key in widget.fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 11, height: 1.35),
                      children: [
                        TextSpan(
                          text: '${labels[key] ?? key}  ',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        TextSpan(
                          text: _values[key] ?? '…',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small grouped-section label inside a sheet (e.g. "Version" / "Audio track").
class _SheetSectionHeader extends StatelessWidget {
  const _SheetSectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
      child: Text(
        label.toUpperCase(),
        style: AppText.caption.copyWith(
          color: AppColors.textTertiary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
