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
    show parseSeason, seasonsOf, cleanTitle;
import '../watch_together/watch_together_controller.dart';
import '../watch_together/ui/room_panel.dart';
import '../../core/app_mode.dart';
import 'player_controller.dart';
import 'player_tv_controls.dart';
import 'seek_preview.dart';

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

  bool _controlsVisible = true;
  // When controls are visible we hide them on tap-DOWN (instant) instead of
  // waiting for onTap's double-tap disambiguation (~300ms), so dismissing feels
  // snappy like CloudStream. We record WHEN that happened so the trailing onTap
  // (which fires ~300ms later) knows to swallow its toggle. A timestamp can't
  // leak the way a bool would when a gesture fires onTapDown but never onTap.
  int _hideOnTapDownMs = 0;
  // We DON'T use Flutter's onDoubleTap — its recognizer delays every single tap
  // ~300ms to disambiguate, which made tapping to reveal controls feel dead. We
  // compare consecutive tap-down timestamps instead, so single taps are instant.
  int _lastTapDownMs = 0; // previous tap-down (a "double" = within 300ms)
  int _seekConsumedMs = 0; // a double-tap seek just fired → swallow the onTap
  bool _holding = false; // long-press 2x active
  Timer? _hideTimer;

  // Double-tap seek indicator (YouTube-style, accumulates on rapid taps).
  Timer? _seekLabelTimer;
  int _seekAccum = 0; // accumulated seconds in the current burst
  int _seekSide = 0; // -1 = left/rewind, +1 = right/forward, 0 = hidden
  Offset? _seekRipplePos; // exact double-tap point for the ink-splash ripple
  int _seekRippleTick = 0; // bumps each tap → restarts the ripple animation

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
  final bool _holdSpeedEnabled = sl<PlaybackPrefs>().holdSpeed;
  final bool _skipIntroEnabled = sl<PlaybackPrefs>().skipIntro;
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

  bool _chatOpen = false; // in-room chat panel visible

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
    if (sl<PlaybackPrefs>().keepScreenOn) WakelockPlus.enable();
    // The volume swipe sets the real system volume; hide the OS volume bar so
    // only our own HUD shows (CloudStream draws its own too). Restored on exit.
    if (_gesturesEnabled) {
      FlutterVolumeController.updateShowSystemUI(false);
    }
    _setupPip();
    if (widget.episodesResolver != null && widget.episodes.isEmpty) {
      _resolveThenStart(); // instant nav: resolve behind the branded loader
    } else {
      _startSession(widget.episodes, widget.startIndex);
    }
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
        Navigator.of(context).maybePop();
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

  void _startSession(List<Episode> eps, int startIndex) {
    _c = PlayerCubit(
      sourceId: widget.sourceId,
      episodes: eps,
      resume: widget.resume,
      resolveSources: widget.resolveSources,
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
    )..init(startIndex);

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
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekLabelTimer?.cancel();
    _hudTimer?.cancel();
    _upNextTimer?.cancel();
    _megaFlashTimer?.cancel();
    _sleepTimer?.cancel();
    _completedSub?.cancel();
    _pipSub?.cancel();
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

  /// Double-tap one side to seek; rapid taps accumulate (−10s, −20s, −30s…)
  /// and the indicator shows on that side, YouTube-style.
  void _accumSeek(int dir) {
    _c.seekBy(Duration(seconds: dir * _seekSeconds));
    if (_seekSide != dir) _seekAccum = 0; // changed direction → restart
    _seekSide = dir;
    _seekAccum += _seekSeconds;
    _seekLabelTimer?.cancel();
    setState(() {});
    _seekLabelTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _seekSide = 0;
          _seekAccum = 0;
        });
      }
    });
    _bumpControls();
  }

  // ── Gestures ────────────────────────────────────────────────────────────

  void _onDoubleTapDown(TapDownDetails d) {
    final w = MediaQuery.of(context).size.width;
    final x = d.localPosition.dx;
    if (x < w / 3) {
      _seekRipplePos = d.localPosition; // splash from where the finger landed
      _seekRippleTick++;
      _accumSeek(-1);
    } else if (x > w * 2 / 3) {
      _seekRipplePos = d.localPosition;
      _seekRippleTick++;
      _accumSeek(1);
    } else {
      _c.togglePlay();
      _bumpControls();
    }
  }

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
          label: iv.type == 'ed' ? 'Skip ending' : 'Skip opening',
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

  void _onEpisodeComplete() {
    // Sleep timer set to "end of episode" — stop here instead of advancing.
    if (_sleepEndOfEpisode) {
      _c.player.pause();
      setState(() {
        _sleepActive = false;
        _sleepEndOfEpisode = false;
      });
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
    _c.playNext();
  }

  void _dismissUpNext() {
    _upNextTimer?.cancel();
    setState(() => _upNext = false);
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
      _SheetColumn(
        header: 'Sleep timer',
        children: [
          _SheetRow(
            label: 'Off',
            active: !_sleepActive,
            onTap: () => choose(null),
          ),
          for (final m in const [15, 30, 45, 60])
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
        ],
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
      });
    }
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
                GestureDetector(
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
      stream: _c.player.stream.position,
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
    _sheet<void>(
      _SheetColumn(
        header: 'Playback Speed',
        children: [
          for (final r in rates)
            _SheetRow(
              label: r == 1.0 ? 'Normal' : '${r}x',
              active: (current - r).abs() < 0.01,
              onTap: () {
                Navigator.pop(context);
                _c.setRateRemembered(r);
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  /// Short label for the in-player decoder button.
  static String _shortDecoder(String mode) => switch (mode) {
        'hw+' => 'HW+',
        'sw' => 'SW',
        'auto' => 'AUTO',
        _ => 'HW',
      };

  /// In-player decoder switch (top-right). Applies LIVE — mpv re-inits the
  /// decoder in place, so a stuttering/green/black stream can be fixed without
  /// leaving the video.
  void _openDecoderSheet() {
    const modes = [
      ('hw', 'Hardware (default)'),
      ('hw+', 'Hardware+ (faster)'),
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
  /// overlay), NOT libass — so font/colour/size/background/position all live
  /// here. Bundled fonts work because Flutter resolves them from pubspec.
  SubtitleViewConfiguration _subtitleConfig() {
    final p = sl<PlaybackPrefs>();
    final fam = p.subtitleFont.isEmpty ? null : p.subtitleFont;
    // position 0 (top) … 100 (bottom). Higher value → nearer the bottom (less
    // bottom padding); lower value lifts the text up the frame.
    final pos = p.subtitlePosition.clamp(0, 100);
    final bottom = 16.0 + (100 - pos) * 3.0;
    return SubtitleViewConfiguration(
      textAlign: TextAlign.center,
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
      style: TextStyle(
        height: 1.4,
        fontSize: 32.0 * p.subtitleScale,
        fontFamily: fam,
        fontWeight: FontWeight.w600,
        color: _parseSubColor(p.subtitleColorHex),
        backgroundColor: Color.fromRGBO(
          0,
          0,
          0,
          p.subtitleBgOpacity.clamp(0.0, 1.0),
        ),
        // A soft shadow keeps text legible when the background box is off.
        shadows: const [Shadow(blurRadius: 4, color: Color(0xCC000000))],
      ),
    );
  }

  /// Parse a `#RRGGBB` or `#RRGGBBAA` hex (the prefs format) into a [Color].
  Color _parseSubColor(String hex) {
    var h = hex.replaceFirst('#', '').toUpperCase();
    if (h.length == 6) h = '${h}FF';
    if (h.length != 8) return const Color(0xFFFFFFFF);
    final r = int.tryParse(h.substring(0, 2), radix: 16) ?? 255;
    final g = int.tryParse(h.substring(2, 4), radix: 16) ?? 255;
    final b = int.tryParse(h.substring(4, 6), radix: 16) ?? 255;
    final a = int.tryParse(h.substring(6, 8), radix: 16) ?? 255;
    return Color.fromARGB(a, r, g, b);
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
          ),
        ),
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
    final scaffold = Scaffold(
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
              else
                // Phone: tap toggles, double-tap seeks, long-press 2×,
                // vertical = brightness/volume, horizontal = scrub.
                // All disabled while locked (only tap-to-reveal-unlock stays).
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Hide instantly on tap-down (no double-tap wait). Showing
                    // still goes through onTap so the first tap of a double-tap
                    // seek doesn't flash the controls.
                    onTapDown: _locked
                        ? null
                        : (d) {
                            final now =
                                DateTime.now().millisecondsSinceEpoch;
                            final second = now - _lastTapDownMs < 300;
                            _lastTapDownMs = now;
                            if (second) {
                              // Second tap of a double → seek by zone. Rapid
                              // taps keep firing this (accumulate −10/−20…).
                              _seekConsumedMs = now;
                              _onDoubleTapDown(d);
                              return;
                            }
                            // First tap: hide instantly if controls are up
                            // (snappy dismiss). Showing happens on tap-up so a
                            // drag/second-tap doesn't falsely reveal controls.
                            if (_controlsVisible) {
                              _hideTimer?.cancel();
                              setState(() => _controlsVisible = false);
                              _hideOnTapDownMs = now;
                            }
                          },
                    onTap: () {
                      final now = DateTime.now().millisecondsSinceEpoch;
                      // Swallow the trailing tap of a double-tap seek…
                      if (now - _seekConsumedMs < 600) return;
                      // …or the tap that just hid controls on tap-down.
                      if (now - _hideOnTapDownMs < 600) return;
                      _toggleControls(); // hidden → show, instantly.
                    },
                    onLongPressStart: (_locked || !_holdSpeedEnabled)
                        ? null
                        : (_) {
                            _c.setRate(2.0);
                            setState(() => _holding = true);
                          },
                    onLongPressEnd: (_locked || !_holdSpeedEnabled)
                        ? null
                        : (_) {
                            _c.setRate(1.0);
                            setState(() => _holding = false);
                          },
                    onVerticalDragStart: _locked ? null : _onVDragStart,
                    onVerticalDragUpdate: _locked ? null : _onVDragUpdate,
                    onVerticalDragEnd: _locked ? null : _onVDragEnd,
                    onHorizontalDragStart: _locked ? null : _onHDragStart,
                    onHorizontalDragUpdate: _locked ? null : _onHDragUpdate,
                    onHorizontalDragEnd: _locked ? null : _onHDragEnd,
                  ),
                ),

              // 3. Buffering spinner when controls are hidden.
              StreamBuilder<bool>(
                stream: _c.player.stream.buffering,
                builder: (context, snap) {
                  final buffering = snap.data ?? false;
                  if (!buffering || _controlsVisible) {
                    return const SizedBox.shrink();
                  }
                  return const Center(
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                        strokeWidth: 2.5,
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

              // 3c. Ink-splash ripple from the exact double-tap point (drawn
              // under the side badge). The tap-tick key recreates it each tap so
              // every double-tap re-pulses, even mid-burst.
              if (_seekSide != 0 && _seekRipplePos != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _SeekRipple(
                      key: ValueKey(_seekRippleTick),
                      position: _seekRipplePos!,
                    ),
                  ),
                ),

              // 4. Double-tap seek indicator — a ripple + animated chevrons +
              // the accumulated amount (−10s, −20s… / +10s, +20s…), pinned to
              // the tapped side and re-pulsing on each rapid tap (YouTube-style).
              if (_seekSide != 0)
                _SeekIndicator(
                  side: _seekSide,
                  // The accumulated value doubles as an animation trigger: each
                  // new tap bumps it, restarting the ripple via the widget key.
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
                    alignment: _hudIsBrightness
                        ? const Alignment(-0.88, 0.0) // left rail = brightness
                        : const Alignment(0.88, 0.0), // right rail = volume
                    child: _AdjustHud(
                      value: _hudValue,
                      isBrightness: _hudIsBrightness,
                    ),
                  ),
                ),
              ),

              // 5. 2x-hold chip (top-center).
              if (_holding)
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        child: Text(
                          '2x ▶▶',
                          style: AppText.caption.copyWith(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                          ),
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
                  duration: const Duration(milliseconds: 220),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _ControlsOverlay(
                      controller: _c,
                      state: state,
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
                    ),
                  ),
                )
              else if (!sl<AppMode>().isTv) // phone locked: show unlock button
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RoundIconButton(
                            icon: Icons.lock_rounded,
                            onTap: _toggleLock,
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

              // 6c. Skip button — accurate AniSkip OP/ED intervals (anime) when
              // detected. Independent of the controls (stays visible like
              // Netflix). No blind/hardcoded fallback — the manual jump-forward
              // is MegaSkip (6c-ii) below.
              if (!_locked && !_upNext && !sl<AppMode>().isTv)
                StreamBuilder<Duration>(
                  stream: _c.player.stream.position,
                  builder: (context, snap) {
                    final btn = _skipButtonFor(snap.data ?? Duration.zero);
                    if (btn == null) return const SizedBox.shrink();
                    return Align(
                      alignment: const Alignment(0.94, 0.66),
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
            ],
            ),
          );
        },
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
    return scaffold;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Percentage on top.
            Text(
              '$pct%',
              style: AppText.caption.copyWith(
                color: tint,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            // Vertical fill track (bottom-anchored) — glides to each value and
            // the accent fill carries a soft glow.
            SizedBox(
              width: 8,
              height: 150,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(4),
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
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: [
                            BoxShadow(
                              color: fillColor.withValues(alpha: 0.55),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Icon at the bottom.
            Icon(_icon, color: tint, size: 24),
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
  const _SeekIndicator({required this.side, required this.accumSeconds});

  final int side; // -1 = rewind (left), +1 = forward (right)
  final int accumSeconds; // total seconds this burst (drives the label + pulse)

  @override
  State<_SeekIndicator> createState() => _SeekIndicatorState();
}

class _SeekIndicatorState extends State<_SeekIndicator>
    with TickerProviderStateMixin {
  // One controller drives the ripple pulse; restarted on every tap.
  late final AnimationController _pulse;
  // A continuously looping controller animates the three chevrons in sequence.
  late final AnimationController _chevrons;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    )..forward();
    _chevrons = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant _SeekIndicator old) {
    super.didUpdateWidget(old);
    // Each rapid tap bumps accumSeconds — restart the ripple to re-pulse.
    if (old.accumSeconds != widget.accumSeconds) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _chevrons.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final back = widget.side < 0;
    return Align(
      alignment: back ? const Alignment(-0.6, 0) : const Alignment(0.6, 0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Expanding, fading ripple behind the badge.
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = Curves.easeOut.transform(_pulse.value);
              return Container(
                width: 150 + 40 * t,
                height: 150 + 40 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.10 * (1 - t)),
                ),
              );
            },
          ),
          // Static dark disc with the chevrons + amount.
          DecoratedBox(
            decoration: const BoxDecoration(
              color: Color(0x73000000),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AnimatedChevrons(back: back, controller: _chevrons),
                  const SizedBox(height: 4),
                  Text(
                    '${back ? '−' : '+'}${widget.accumSeconds}s',
                    style: AppText.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A circular ink-splash that expands and fades from the exact point the user
/// double-tapped — YouTube-style feedback for the ±seek. Recreated (via a
/// ValueKey on the tap counter) on every tap so each one re-pulses.
class _SeekRipple extends StatefulWidget {
  const _SeekRipple({super.key, required this.position});

  final Offset position;

  @override
  State<_SeekRipple> createState() => _SeekRippleState();
}

class _SeekRippleState extends State<_SeekRipple>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_c.value);
        return CustomPaint(
          size: Size.infinite,
          painter: _SeekRipplePainter(
            center: widget.position,
            radius: 40 + 200 * t,
            alpha: 0.18 * (1 - t),
          ),
        );
      },
    );
  }
}

class _SeekRipplePainter extends CustomPainter {
  _SeekRipplePainter({
    required this.center,
    required this.radius,
    required this.alpha,
  });

  final Offset center;
  final double radius;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    if (alpha <= 0) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Colors.white.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_SeekRipplePainter old) =>
      old.radius != radius || old.alpha != alpha || old.center != center;
}

/// Three chevrons that brighten in sequence (pointing back when rewinding,
/// forward when seeking ahead), giving the badge a "moving" feel.
class _AnimatedChevrons extends StatelessWidget {
  const _AnimatedChevrons({required this.back, required this.controller});

  final bool back;
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    final icon = back
        ? Icons.keyboard_arrow_left_rounded
        : Icons.keyboard_arrow_right_rounded;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Three staggered phases (0,1,2) cycle so chevrons light up in order;
        // when rewinding the order is reversed so motion reads right-to-left.
        final phase = (controller.value * 3).floor() % 3;
        Widget chev(int index) {
          final logical = back ? 2 - index : index;
          final active = logical == phase;
          return Icon(
            icon,
            size: 26,
            color: Colors.white.withValues(alpha: active ? 1.0 : 0.4),
          );
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Overlap the chevrons slightly for a tight ">>>" cluster.
            chev(0),
            Transform.translate(offset: const Offset(-12, 0), child: chev(1)),
            Transform.translate(offset: const Offset(-24, 0), child: chev(2)),
          ],
        );
      },
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
    final hasNext = state.currentIndex + 1 < c.episodes.length;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Top scrim.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 120,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC000000), Color(0x00000000)],
              ),
            ),
          ),
        ),
        // Bottom scrim.
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 200,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xE6000000), Color(0x00000000)],
              ),
            ),
          ),
        ),

        // Soft gradient scrims so the controls sit on a gentle fade, not a flat
        // dark wash (YouTube/Dantotsu-style). Non-interactive.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 120,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
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
                  colors: [Color(0xB3000000), Color(0x00000000)],
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    onPressed: onBack,
                  ),
                  Expanded(
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
                        if (secondaryTitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              secondaryTitle,
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
                  // Decoder quick-switch (top-right) — tap to flip HW/SW live if
                  // a stream stutters / goes green / black. Aniyomi-style.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      onTap: onDecoder,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white54),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          decoderLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // PiP + episodes + sleep + lock (top-right). Zoom is bottom row.
                  if (onPip != null)
                    IconButton(
                      icon: const Icon(
                        Icons.picture_in_picture_alt_rounded,
                        color: Colors.white,
                      ),
                      onPressed: onPip,
                    ),
                  if (onEpisodes != null)
                    IconButton(
                      icon: const Icon(
                        Icons.video_library_outlined,
                        color: Colors.white,
                      ),
                      onPressed: onEpisodes,
                    ),
                  IconButton(
                    icon: Icon(
                      sleepActive
                          ? Icons.bedtime_rounded
                          : Icons.bedtime_outlined,
                      color: sleepActive ? AppColors.accent : Colors.white,
                    ),
                    onPressed: onSleep,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.lock_open_rounded,
                      color: Colors.white,
                    ),
                    onPressed: onLock,
                  ),
                  if (onChat != null)
                    IconButton(
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: Colors.white,
                      ),
                      onPressed: onChat,
                    ),
                ],
              ),
            ),
          ),
        ),

        // Center transport.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SeekButton(
                icon: Icons.replay_10_rounded,
                forward: false,
                onTap: () {
                  c.seekBy(const Duration(seconds: -10));
                  onInteract();
                },
              ),
              const SizedBox(width: 24),
              StreamBuilder<bool>(
                stream: c.player.stream.buffering,
                builder: (context, bSnap) {
                  final buffering = bSnap.data ?? c.player.state.buffering;
                  // While buffering, show the spinner IN PLACE OF the play/pause
                  // button (same 72px footprint so the row doesn't shift) — no
                  // more spinner-over-button overlap.
                  if (buffering) {
                    return const SizedBox(
                      width: 62,
                      height: 62,
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
              const SizedBox(width: 24),
              _SeekButton(
                icon: Icons.forward_10_rounded,
                forward: true,
                onTap: () {
                  c.seekBy(const Duration(seconds: 10));
                  onInteract();
                },
              ),
            ],
          ),
        ),

        // Bottom: seek row + button row.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // MegaSkip — manual jump-forward pill, right-aligned just
                  // above the seek bar (Aniyomi-style). Only when enabled.
                  if (megaSkipEnabled)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8, right: 2),
                        child: _MegaSkipPill(
                          seconds: megaSkipSeconds,
                          onTap: onMegaSkip,
                        ),
                      ),
                    ),
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
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  // Button row: every control evenly distributed edge-to-edge
                  // (Previous flush-left, Next flush-right, uniform gaps).
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (onPrev != null)
                        _ControlButton(
                          icon: Icons.skip_previous_rounded,
                          label: 'Previous',
                          onTap: onPrev!,
                        ),
                      _ControlButton(
                        icon: Icons.speed_rounded,
                        label: 'Speed',
                        onTap: onSpeed,
                      ),
                      _ControlButton(
                        icon: Icons.subtitles_rounded,
                        label: 'Audio & subs',
                        onTap: onAudioSubs,
                      ),
                      if (state.qualities.isNotEmpty ||
                          c.sourceQualities.length > 1)
                        _ControlButton(
                          icon: Icons.high_quality_rounded,
                          label: 'Quality',
                          onTap: onQuality,
                        ),
                      _ControlButton(
                        icon: Icons.video_settings_rounded,
                        label: 'Sources',
                        onTap: onSources,
                      ),
                      _ControlButton(
                        icon: Icons.aspect_ratio_rounded,
                        label: zoomLabel,
                        onTap: onZoom,
                      ),
                      if (hasNext)
                        _ControlButton(
                          icon: Icons.skip_next_rounded,
                          label: 'Next',
                          onTap: () {
                            c.playNext();
                            onInteract();
                          },
                        ),
                    ],
                  ),
                ],
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
  });

  final PlayerCubit controller;
  final Duration duration;
  final VoidCallback onInteract;

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  // While the user is dragging the thumb, hold the value locally so the live
  // position stream doesn't yank it back (which made it feel un-draggable).
  double? _dragMs;

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
    // Offline files always preview (instant/free); online honours the setting.
    return c.isLocalMedia || sl<PlaybackPrefs>().seekPreviewOnline;
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
      stream: widget.controller.player.stream.position,
      builder: (context, snap) {
        final streamMs = (snap.data ?? Duration.zero).inMilliseconds
            .clamp(0, max.toInt())
            .toDouble();
        // Use the drag value while scrubbing, else the live position.
        final value = (_dragMs ?? streamMs).clamp(0.0, max);
        final shownPos = Duration(milliseconds: value.round());
        return Row(
          children: [
            Text(
              _fmt(shownPos),
              style: AppText.caption.copyWith(color: Colors.white),
            ),
            Expanded(
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
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _showRemaining = !_showRemaining);
                widget.onInteract();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Text(
                  _showRemaining
                      ? '-${_fmt(widget.duration - shownPos)}'
                      : _fmt(widget.duration),
                  style: AppText.caption.copyWith(color: Colors.white),
                ),
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

// Netflix-style "Skip intro" pill.
class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Colors.white70, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppText.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.fast_forward_rounded,
                color: Colors.white,
                size: 18,
              ),
            ],
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
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: StadiumBorder(
        side: BorderSide(
          color: AppColors.accent.withValues(alpha: 0.7),
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.keyboard_double_arrow_right_rounded,
                color: AppColors.accent,
                size: 17,
              ),
              const SizedBox(width: 4),
              Text(
                '+${seconds}s',
                style: AppText.caption.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
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
  const _RoundIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
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
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 3),
            Text(label, style: AppText.caption.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
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
  static const double _cardH = 78;
  static const double _headerH = 34;

  late final bool _multiSeason;
  late final List<_PanelItem> _items;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    _multiSeason = seasonsOf(widget.episodes).length > 1;
    _items = _buildItems();
    _scroll = ScrollController(initialScrollOffset: _offsetToCurrent());
  }

  List<_PanelItem> _buildItems() {
    if (!_multiSeason) {
      return [
        for (var i = 0; i < widget.episodes.length; i++) _PanelItem.episode(i),
      ];
    }
    final bySeason = <int, List<int>>{};
    for (var i = 0; i < widget.episodes.length; i++) {
      (bySeason[parseSeason(widget.episodes[i].title) ?? 1] ??= []).add(i);
    }
    final out = <_PanelItem>[];
    for (final s in bySeason.keys.toList()..sort()) {
      out.add(_PanelItem.header(s));
      for (final i in bySeason[s]!) {
        out.add(_PanelItem.episode(i));
      }
    }
    return out;
  }

  /// Approx pixel offset so the list opens near the current episode.
  double _offsetToCurrent() {
    var offset = 0.0;
    for (final it in _items) {
      if (it.isHeader) {
        offset += _headerH;
      } else {
        if (it.index == widget.currentIndex) break;
        offset += _cardH;
      }
    }
    return offset > _cardH * 2
        ? offset - _cardH * 2
        : 0; // leave a little above
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final panelW = (w * 0.42).clamp(300.0, 480.0);
    return Material(
      color: Colors.transparent,
      child: FrostedSurface(
        blur: true,
        opacity: 0.88,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
        child: SizedBox(
          width: panelW,
          height: double.infinity,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 6, 8),
                  child: Row(
                    children: [
                      Expanded(child: Text('Episodes', style: AppText.title)),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: _items.length,
                    itemBuilder: (c, k) {
                      final it = _items[k];
                      if (it.isHeader) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'SEASON ${it.season}',
                            style: AppText.caption.copyWith(
                              color: AppColors.textTertiary,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        );
                      }
                      return _card(widget.episodes[it.index], it.index);
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

  Widget _card(Episode e, int i) {
    final cur = i == widget.currentIndex;
    final n = e.number?.toInt() ?? (i + 1);
    final raw = e.title.trim();
    final title = _multiSeason ? cleanTitle(raw) : raw;
    final hasTitle = title.isNotEmpty && title != 'Episode $n';
    final cover = widget.cover;
    final coverHeaders = widget.coverHeaders;
    final onSelect = widget.onSelect;
    final thumb = (e.thumbnail != null && e.thumbnail!.isNotEmpty)
        ? e.thumbnail!
        : (cover ?? '');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onSelect(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 104,
                  height: 58, // 16:9
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      thumb.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: thumb,
                              httpHeaders: coverHeaders,
                              fit: BoxFit.cover,
                              memCacheWidth: 240,
                              placeholder: (c, u) =>
                                  const ColoredBox(color: AppColors.surface2),
                              errorWidget: (c, u, e) =>
                                  const ColoredBox(color: AppColors.surface2),
                            )
                          : const ColoredBox(color: AppColors.surface2),
                      if (cur)
                        const DecoratedBox(
                          decoration: BoxDecoration(color: Color(0x55000000)),
                          child: Center(
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'E$n',
                      style: AppText.body.copyWith(
                        color: cur ? AppColors.accent : AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (hasTitle)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          title,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
  });
  final PlayerCubit controller;
  final VoidCallback onInteract;
  final VoidCallback onLoadFile;
  final VoidCallback onSearchOnline;

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
                  // Aniyomi-style two-tap auto-sync (subtitle only).
                  positionMs: () => c.player.state.position.inMilliseconds,
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
                    _openSubtitleStyleSheet(context, c, widget.onInteract);
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
      return const Padding(
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
          const Positioned.fill(
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
void _openSubtitleStyleSheet(
  BuildContext context,
  PlayerCubit controller,
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
  final PlayerCubit controller;
  final VoidCallback onInteract;

  @override
  State<_SubtitleStyleSheet> createState() => _SubtitleStyleSheetState();
}

class _SubtitleStyleSheetState extends State<_SubtitleStyleSheet> {
  PlaybackPrefs get _prefs => sl<PlaybackPrefs>();

  // Text-colour swatches, stored as #RRGGBBAA (opaque).
  static const List<(String, String)> _colors = [
    ('#FFFFFFFF', 'White'),
    ('#FFFF00FF', 'Yellow'),
    ('#00E5FFFF', 'Cyan'),
    ('#7CFC00FF', 'Green'),
    ('#FF6B6BFF', 'Red'),
    ('#000000FF', 'Black'),
  ];

  static const List<(double, String)> _sizes = [
    (0.8, 'Small'),
    (1.0, 'Medium'),
    (1.3, 'Large'),
  ];

  Future<void> _apply(Future<void> Function() mutate) async {
    await mutate();
    await widget.controller.applySubtitleStyle();
    if (mounted) setState(() {});
    widget.onInteract();
  }

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
                          active: font == f,
                          onTap: () => _apply(() => _prefs.setSubtitleFont(f)),
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
                for (final (s, name) in _sizes)
                  _SheetRow(
                    label: name,
                    active: (size - s).abs() < 0.01,
                    onTap: () => _apply(() => _prefs.setSubtitleScale(s)),
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
    return GestureDetector(
      onTap: onTap,
      child: Column(
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
      ),
    );
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
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
            size: 58,
          ),
        ),
      ),
    );
  }
}

/// ±10s seek button — a clean icon (no background) that spins once when tapped
/// (rewind spins back, forward spins ahead). Apple-style: just the icon.
class _SeekButton extends StatefulWidget {
  const _SeekButton({
    required this.icon,
    required this.forward,
    required this.onTap,
  });
  final IconData icon;
  final bool forward;
  final VoidCallback onTap;

  @override
  State<_SeekButton> createState() => _SeekButtonState();
}

class _SeekButtonState extends State<_SeekButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final Animation<double> _turn = Tween<double>(
    begin: 0,
    end: widget.forward ? 1 : -1,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _tap() {
    _ctrl.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _tap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: RotationTransition(
          turns: _turn,
          child: Icon(widget.icon, color: Colors.white, size: 34),
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
        Flexible(child: ListView(shrinkWrap: true, children: children)),
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
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  /// Optional trailing icon (e.g. upload for "Load from file…").
  final IconData? icon;

  /// Optional secondary line under the label — explains what a setting does
  /// (e.g. for jargon like "Audio normalization") so it's self-describing.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    // Netflix-style: the selected row is tinted + accent-bold with a trailing
    // check; others are plain.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: active ? AppColors.accentSoft : Colors.transparent,
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
                          color: active
                              ? AppColors.accent
                              : AppColors.textPrimary,
                          fontWeight: active
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
                if (icon != null)
                  Icon(icon, color: AppColors.textSecondary, size: 20)
                else if (active)
                  const Icon(
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
    this.positionMs,
  });
  final String label;
  final Duration initial;
  final ValueChanged<Duration> onChanged;

  /// When set, shows the Aniyomi-style two-tap auto-sync below the stepper.
  /// Returns the current playback position (ms) at the moment of a tap.
  final int Function()? positionMs;

  @override
  State<_DelayAdjuster> createState() => _DelayAdjusterState();
}

class _DelayAdjusterState extends State<_DelayAdjuster> {
  late int _ms = widget.initial.inMilliseconds;
  static const int _step = 250;

  // Two-tap sync captures: playback position when the voice was heard and when
  // the subtitle was seen. Delay adjustment = voice − text (which cancels the
  // roughly-equal human reaction lag on both taps).
  int? _voiceMs;
  int? _textMs;
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
    final pos = widget.positionMs!();
    if (voice) {
      _voiceMs = pos;
    } else {
      _textMs = pos;
    }
    if (_voiceMs != null && _textMs != null) {
      final delta = _voiceMs! - _textMs!;
      _voiceMs = null;
      _textMs = null;
      _bump(delta); // folds the alignment into the delay + applies it
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
              _stepBtn(Icons.remove_rounded, () => _bump(-_step)),
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
              _stepBtn(Icons.add_rounded, () => _bump(_step)),
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
        if (widget.positionMs != null) _syncSection(),
      ],
    );
  }

  Widget _syncSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _note ??
                'Auto-sync: tap when you HEAR a line, then when its SUBTITLE '
                    'appears.',
            style: AppText.caption.copyWith(
              color: _note != null ? AppColors.accent : AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _syncBtn(
                  'Voice heard',
                  Icons.hearing_rounded,
                  _voiceMs != null,
                  () => _capture(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _syncBtn(
                  'Subtitle seen',
                  Icons.subtitles_rounded,
                  _textMs != null,
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

  Widget _stepBtn(IconData icon, VoidCallback onTap) => Material(
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
  );
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
