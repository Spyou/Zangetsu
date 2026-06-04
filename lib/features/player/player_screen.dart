import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart' show Track;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/brand_loader.dart';
import '../../core/ui/frosted_surface.dart';
import '../detail/cubit/detail_cubit.dart'
    show parseSeason, seasonsOf, cleanTitle;
import 'player_controller.dart';
import 'seek_preview.dart';

/// Netflix-style fullscreen player: a live [Video] with a tap-to-toggle
/// overlay (auto-hiding), double-tap ±10s seek, long-press 2x speed, a
/// stream-bound seek slider, and Speed / Audio / Quality / Source / Next
/// controls. Forces landscape + immersive UI while open and restores portrait
/// on dispose.
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
    this.history,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.showUrl,
    this.category,
    this.availableCategories = const [],
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

  // Optional show-context threaded into history (Continue Watching feed).
  final WatchHistory? history;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String? showUrl;
  final String? category;

  /// Sub/Dub categories this title offers. When length <= 1 the player hides
  /// the Version (Sub/Dub) section. Switching re-resolves the current episode
  /// in the chosen language (see [PlayerCubit.switchCategory]).
  final List<String> availableCategories;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerCubit _c;

  bool _controlsVisible = true;
  // When controls are visible we hide them on tap-DOWN (instant) instead of
  // waiting for onTap's double-tap disambiguation (~300ms), so dismissing feels
  // snappy like CloudStream. We record WHEN that happened so the trailing onTap
  // (which fires ~300ms later) knows to swallow its toggle. A timestamp can't
  // leak the way a bool would when a gesture fires onTapDown but never onTap.
  int _hideOnTapDownMs = 0;
  bool _holding = false; // long-press 2x active
  Timer? _hideTimer;

  // Double-tap seek indicator (YouTube-style, accumulates on rapid taps).
  Timer? _seekLabelTimer;
  int _seekAccum = 0; // accumulated seconds in the current burst
  int _seekSide = 0; // -1 = left/rewind, +1 = right/forward, 0 = hidden

  // Duration tracked off the stream so the slider has a max even before
  // a position event arrives.
  Duration _duration = Duration.zero;

  // User's preferred double-tap seek step, read once at session start.
  final int _seekSeconds = sl<PlaybackPrefs>().seekSeconds;

  // ── Brightness / volume swipe gestures ──────────────────────────────────
  final bool _gesturesEnabled = sl<PlaybackPrefs>().gestureControls;
  final bool _holdSpeedEnabled = sl<PlaybackPrefs>().holdSpeed;
  final bool _skipIntroEnabled = sl<PlaybackPrefs>().skipIntro;
  bool _dragIsBrightness = false; // left half = brightness, right half = volume
  double _dragValue = 0; // running 0..1 value during a vertical drag
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

  bool _ready = false; // the player session (cubit) is built

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (sl<PlaybackPrefs>().keepScreenOn) WakelockPlus.enable();
    if (widget.episodesResolver != null && widget.episodes.isEmpty) {
      _resolveThenStart(); // instant nav: resolve behind the branded loader
    } else {
      _startSession(widget.episodes, widget.startIndex);
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
      availableCategories: widget.availableCategories,
    )..init(startIndex);
    // Drive the "Up next" card on episode completion (the controller no longer
    // auto-advances; we show a 5s countdown card instead).
    _completedSub = _c.player.stream.completed.listen((done) {
      if (done) _onEpisodeComplete();
    });
    if (mounted) setState(() => _ready = true);
    _scheduleHide();
  }

  Future<void> _resolveThenStart() async {
    try {
      final eps = await widget.episodesResolver!();
      if (!mounted) return;
      if (eps.isEmpty) {
        Navigator.of(context).maybePop();
        return;
      }
      var idx = 0;
      if (widget.resumeEpisodeId != null) {
        final i = eps.indexWhere((e) => e.id == widget.resumeEpisodeId);
        if (i >= 0) idx = i;
      }
      _startSession(eps, idx);
    } catch (_) {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekLabelTimer?.cancel();
    _hudTimer?.cancel();
    _upNextTimer?.cancel();
    _sleepTimer?.cancel();
    _completedSub?.cancel();
    // Hand brightness back to the system when leaving the player.
    if (_gesturesEnabled) {
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (_) {},
      );
    }
    WakelockPlus.disable();
    if (_ready) _c.close();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
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
      _accumSeek(-1);
    } else if (x > w * 2 / 3) {
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
    _dragIsBrightness =
        d.localPosition.dx < MediaQuery.of(context).size.width / 2;
    if (_dragIsBrightness) {
      try {
        _dragValue = await ScreenBrightness.instance.application;
      } catch (_) {
        _dragValue = 0.5;
      }
    } else {
      _dragValue = (_c.player.state.volume / 100).clamp(0.0, 1.0);
    }
  }

  void _onVDragUpdate(DragUpdateDetails d) {
    if (!_gesturesEnabled) return;
    final h = MediaQuery.of(context).size.height;
    // Drag up (negative delta) increases the value.
    _dragValue = (_dragValue - d.primaryDelta! / (h * 0.7)).clamp(0.0, 1.0);
    if (_dragIsBrightness) {
      ScreenBrightness.instance
          .setApplicationScreenBrightness(_dragValue)
          .catchError((_) {});
    } else {
      _c.player.setVolume(_dragValue * 100);
    }
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
    if (!_hSeeking) return;
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

  // ── Sheets ──────────────────────────────────────────────────────────────

  Future<T?> _sheet<T>(Widget child) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => FrostedSurface(
        blur: true,
        opacity: 0.75,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                _c.setRate(r);
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  /// Netflix-style combined Audio | Subtitles panel (two columns, live
  /// selection without closing).
  void _openAudioSubsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => FrostedSurface(
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
            _c.selectQuality(null);
            _bumpControls();
          },
        ),
        for (final v in _c.state.qualities)
          _SheetRow(
            label: v.quality,
            active: _c.state.activeQuality?.url == v.url,
            onTap: () {
              Navigator.pop(context);
              _c.selectQuality(v);
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
              _c.selectSourceQuality(q);
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
                // server); fall back to kind + quality/container otherwise.
                label: s.label?.isNotEmpty == true
                    ? s.label!
                    : '${k.name.toUpperCase()} • '
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

  @override
  Widget build(BuildContext context) {
    // Still resolving the episode list (instant-nav path) — show the branded
    // loader instead of touching the not-yet-created cubit.
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: BrandLoader(label: 'Loading…')),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: BlocBuilder<PlayerCubit, PlayerState>(
        bloc: _c,
        builder: (context, state) {
          if (state.loadingSources) {
            return const Center(
              child: BrandLoader(label: 'Finding the best source…'),
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
          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. The video. NoVideoControls disables media_kit's built-in
              // controls (which include their own buffering spinner + gestures)
              // so ONLY our custom Netflix overlay shows — fixes the duplicate
              // spinner / double controls.
              Center(
                child: Video(
                  controller: _c.videoController,
                  controls: NoVideoControls,
                  fit: _fits[_fitIndex].$1,
                ),
              ),

              // 2. Gesture surface: tap toggles, double-tap seeks, long-press 2x,
              // vertical = brightness/volume, horizontal = scrub. All disabled
              // while locked (only the tap-to-reveal-unlock stays).
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Hide instantly on tap-down (no double-tap wait). Showing
                  // still goes through onTap so the first tap of a double-tap
                  // seek doesn't flash the controls.
                  onTapDown: (_locked || !_controlsVisible)
                      ? null
                      : (_) {
                          _hideTimer?.cancel();
                          setState(() => _controlsVisible = false);
                          _hideOnTapDownMs =
                              DateTime.now().millisecondsSinceEpoch;
                        },
                  onTap: () {
                    // Swallow the toggle if we just hid on tap-down.
                    if (DateTime.now().millisecondsSinceEpoch -
                            _hideOnTapDownMs <
                        600) {
                      return;
                    }
                    _toggleControls();
                  },
                  onDoubleTapDown: _locked ? null : _onDoubleTapDown,
                  onDoubleTap: _locked ? null : () {},
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

              // 4. Double-tap seek indicator — pinned to the tapped side, with
              // the accumulated amount (−10s, −20s… / +10s, +20s…).
              if (_seekSide != 0)
                Align(
                  alignment: _seekSide < 0
                      ? const Alignment(-0.55, 0)
                      : const Alignment(0.55, 0),
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0x73000000),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _seekSide < 0
                                ? Icons.fast_rewind_rounded
                                : Icons.fast_forward_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_seekSide < 0 ? '−' : '+'}$_seekAccum s',
                            style: AppText.body.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 4b. Brightness / volume HUD (Netflix-style) while swiping —
              // pinned to the side being adjusted (left = brightness,
              // right = volume).
              if (_hudVisible)
                Align(
                  alignment: _hudIsBrightness
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                    child: _AdjustHud(
                      value: _hudValue,
                      isBrightness: _hudIsBrightness,
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

              // 6. Controls overlay — or, when locked, just an unlock button.
              if (!_locked)
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
                      onSleep: _openSleepSheet,
                      sleepActive: _sleepActive,
                      onEpisodes: _c.episodes.length > 1
                          ? _openEpisodesPanel
                          : null,
                      onPrev: _c.state.currentIndex > 0
                          ? () {
                              _c.playPrevious();
                              _bumpControls();
                            }
                          : null,
                    ),
                  ),
                )
              else
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

              // 6c. Skip button — accurate AniSkip OP/ED intervals when
              // available (anime), else the manual "Skip intro" early on.
              // Independent of the controls (stays visible like Netflix).
              if (!_locked && !_upNext)
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

              // 7. Up-next card (auto-advance countdown).
              if (_upNext) _buildUpNextCard(),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Brightness / volume HUD — a compact dark pill with an icon, a vertical fill
// bar and a percentage, shown centered while the user swipes (Netflix-style).
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
    final pct = (value * 100).round();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, color: Colors.white, size: 26),
            const SizedBox(height: 12),
            // Vertical fill bar.
            SizedBox(
              width: 6,
              height: 110,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Colors.white24),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: value.clamp(0.0, 1.0),
                        child: const ColoredBox(color: AppColors.accent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '$pct%',
              style: AppText.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
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
    required this.onEpisodes,
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
  final VoidCallback? onEpisodes; // null = single episode (no picker)

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
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
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
                  // Episodes + sleep + lock (top-right). Zoom is in bottom row.
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
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.replay_10, color: Colors.white),
                onPressed: () {
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
                      width: 72,
                      height: 72,
                      child: Center(
                        child: SizedBox(
                          width: 34,
                          height: 34,
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
                      return IconButton(
                        iconSize: 56,
                        icon: Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          c.togglePlay();
                          onInteract();
                        },
                      );
                    },
                  );
                },
              ),
              const SizedBox(width: 24),
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.forward_10, color: Colors.white),
                onPressed: () {
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
                          icon: Icons.skip_previous,
                          label: 'Previous',
                          onTap: onPrev!,
                        ),
                      _ControlButton(
                        icon: Icons.speed,
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
                          icon: Icons.high_quality,
                          label: 'Quality',
                          onTap: onQuality,
                        ),
                      _ControlButton(
                        icon: Icons.video_settings,
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
                          icon: Icons.skip_next,
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
                  const bubbleW = 132.0;
                  final left = (frac * w - bubbleW / 2).clamp(
                    0.0,
                    (w - bubbleW).clamp(0.0, double.infinity),
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        width: w,
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
                    width: 132,
                    height: 74,
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
  });
  final PlayerCubit controller;
  final VoidCallback onInteract;
  final VoidCallback onLoadFile;

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
              ),
              _DelayAdjuster(
                label: 'Audio delay',
                initial: c.audioDelay,
                onChanged: (d) => c.setAudioDelay(d),
              ),
            ],
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
                  active: false,
                  onTap: () {
                    c.setSoftSub(s);
                    widget.onInteract();
                  },
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

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  /// Optional trailing icon (e.g. upload for "Load from file…").
  final IconData? icon;

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
                  child: Text(
                    label,
                    style: AppText.body.copyWith(
                      color: active ? AppColors.accent : AppColors.textPrimary,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
  });
  final String label;
  final Duration initial;
  final ValueChanged<Duration> onChanged;

  @override
  State<_DelayAdjuster> createState() => _DelayAdjusterState();
}

class _DelayAdjusterState extends State<_DelayAdjuster> {
  late int _ms = widget.initial.inMilliseconds;
  static const int _step = 250;

  void _bump(int delta) {
    setState(() => _ms = (_ms + delta).clamp(-30000, 30000));
    widget.onChanged(Duration(milliseconds: _ms));
  }

  @override
  Widget build(BuildContext context) {
    final secs = (_ms / 1000).toStringAsFixed(2);
    final shown = _ms > 0 ? '+${secs}s' : '${secs}s';
    return Padding(
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
