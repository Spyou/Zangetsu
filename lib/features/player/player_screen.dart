import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
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
import 'player_controller.dart';

/// Netflix-style fullscreen player: a live [Video] with a tap-to-toggle
/// overlay (auto-hiding), double-tap ±10s seek, long-press 2x speed, a
/// stream-bound seek slider, and Speed / Audio / Quality / Source / Next
/// controls. Forces landscape + immersive UI while open and restores portrait
/// on dispose.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.sourceId,
    required this.episodes,
    required this.startIndex,
    required this.resume,
    required this.resolveSources,
    this.history,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.showUrl,
    this.category,
    this.availableCategories = const [],
  });

  final String sourceId;
  final List<Episode> episodes;
  final int startIndex;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;

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
  bool _holding = false; // long-press 2x active
  Timer? _hideTimer;

  // Transient ±10 seek label.
  String? _seekLabel;
  Timer? _seekLabelTimer;

  // Duration tracked off the stream so the slider has a max even before
  // a position event arrives.
  Duration _duration = Duration.zero;

  // User's preferred double-tap seek step, read once at session start.
  final int _seekSeconds = sl<PlaybackPrefs>().seekSeconds;

  // ── Brightness / volume swipe gestures ──────────────────────────────────
  final bool _gesturesEnabled = sl<PlaybackPrefs>().gestureControls;
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

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (sl<PlaybackPrefs>().keepScreenOn) WakelockPlus.enable();
    _c = PlayerCubit(
      sourceId: widget.sourceId,
      episodes: widget.episodes,
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
    )..init(widget.startIndex);
    _scheduleHide();
    // Drive the "Up next" card on episode completion (the controller no longer
    // auto-advances; we show a 5s countdown card instead).
    _completedSub = _c.player.stream.completed.listen((done) {
      if (done) _onEpisodeComplete();
    });
  }

  StreamSubscription<bool>? _completedSub;

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
    _c.close();
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

  void _showSeekLabel(String label) {
    _seekLabelTimer?.cancel();
    setState(() => _seekLabel = label);
    _seekLabelTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekLabel = null);
    });
  }

  // ── Gestures ────────────────────────────────────────────────────────────

  void _onDoubleTapDown(TapDownDetails d) {
    final w = MediaQuery.of(context).size.width;
    final x = d.localPosition.dx;
    if (x < w / 3) {
      _c.seekBy(Duration(seconds: -_seekSeconds));
      _showSeekLabel('-$_seekSeconds');
    } else if (x > w * 2 / 3) {
      _c.seekBy(Duration(seconds: _seekSeconds));
      _showSeekLabel('+$_seekSeconds');
    } else {
      _c.togglePlay();
    }
    _bumpControls();
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

  // ── Episodes picker ───────────────────────────────────────────────────────
  void _openEpisodesSheet() {
    final eps = _c.episodes;
    final cur = _c.state.currentIndex;
    _sheet<void>(
      _SheetColumn(
        header: 'Episodes',
        children: [
          for (var i = 0; i < eps.length; i++)
            _SheetRow(
              label: _episodeLabel(eps[i], i),
              active: i == cur,
              onTap: () {
                Navigator.pop(context);
                if (i != cur) _c.openEpisode(i);
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  String _episodeLabel(Episode e, int i) {
    final n = e.number?.toInt() ?? (i + 1);
    final t = e.title.trim();
    return (t.isEmpty || t == 'Episode $n') ? 'Episode $n' : 'E$n · $t';
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
                          Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 20),
                          SizedBox(width: 4),
                          Text('Play now',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700)),
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
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 20),
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

  void _openAudioSheet() {
    final categories = _c.categories;
    final activeCategory = _c.activeCategory;
    final audioTracks = _c.mediaAudioTracks;
    final activeTrack = _c.activeAudioTrack;
    _sheet<void>(
      _SheetColumn(
        header: 'Audio',
        children: [
          // Version (Sub/Dub) — re-resolves the current episode in the chosen
          // language. Only shown when the title offers more than one category.
          if (categories.length > 1) ...[
            const _SheetSectionHeader('Version'),
            for (final cat in categories)
              _SheetRow(
                label: cat.toUpperCase(),
                active: activeCategory == cat,
                onTap: () {
                  Navigator.pop(context);
                  _c.switchCategory(cat);
                  _bumpControls();
                },
              ),
          ],
          // Embedded audio tracks — only when the media exposes more than one.
          if (audioTracks.length > 1) ...[
            const _SheetSectionHeader('Audio track'),
            for (final t in audioTracks)
              _SheetRow(
                label: t.language ?? t.title ?? t.id,
                active: activeTrack.id == t.id,
                onTap: () {
                  Navigator.pop(context);
                  _c.setAudioTrack(t);
                  _bumpControls();
                },
              ),
          ],
          const _SheetSectionHeader('Sync'),
          _DelayAdjuster(
            label: 'Audio delay',
            initial: _c.audioDelay,
            onChanged: (d) => _c.setAudioDelay(d),
          ),
        ],
      ),
    );
  }

  void _openSubtitlesSheet() {
    final embedded = _c.mediaSubtitleTracks;
    final soft = _c.softSubs;
    final active = _c.activeSubtitleTrack;
    _sheet<void>(
      _SheetColumn(
        header: 'Subtitles',
        children: [
          // Off (CloudStream lists this first).
          _SheetRow(
            label: 'Off',
            active: active.id == 'no',
            onTap: () {
              Navigator.pop(context);
              _c.subtitlesOff();
              _bumpControls();
            },
          ),
          // Embedded subtitle tracks.
          for (final t in embedded)
            _SheetRow(
              label: '${t.title ?? t.language ?? t.id} (embedded)',
              active: active.id == t.id,
              onTap: () {
                Navigator.pop(context);
                _c.setSubtitle(t);
                _bumpControls();
              },
            ),
          // External "soft" subtitles advertised by the source.
          for (final s in soft)
            _SheetRow(
              label: s.label ?? s.lang,
              active: false,
              onTap: () {
                Navigator.pop(context);
                _c.setSoftSub(s);
                _bumpControls();
              },
            ),
          // Load a subtitle file from disk.
          _SheetRow(
            label: 'Load from file…',
            icon: Icons.upload_file,
            active: false,
            onTap: () {
              Navigator.pop(context);
              _loadSubtitleFromFile();
            },
          ),
          const _SheetSectionHeader('Sync'),
          _DelayAdjuster(
            label: 'Subtitle delay',
            initial: _c.subtitleDelay,
            onChanged: (d) => _c.setSubtitleDelay(d),
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
                  _c.switchSource(s);
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
                  onTap: _toggleControls,
                  onDoubleTapDown: _locked ? null : _onDoubleTapDown,
                  onDoubleTap: _locked ? null : () {},
                  onLongPressStart: _locked
                      ? null
                      : (_) {
                          _c.setRate(2.0);
                          setState(() => _holding = true);
                        },
                  onLongPressEnd: _locked
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

              // 4. ±10 seek label.
              if (_seekLabel != null)
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      child: Text(
                        '$_seekLabel s',
                        style: AppText.headline.copyWith(color: Colors.white),
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
                      onAudio: _openAudioSheet,
                      onSubtitles: _openSubtitlesSheet,
                      onQuality: _openQualitySheet,
                      onSources: _openSourceSheet,
                      onLock: _toggleLock,
                      onZoom: _cycleFit,
                      onSleep: _openSleepSheet,
                      sleepActive: _sleepActive,
                      onEpisodes:
                          _c.episodes.length > 1 ? _openEpisodesSheet : null,
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
    required this.onAudio,
    required this.onSubtitles,
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
  final VoidCallback onAudio;
  final VoidCallback onSubtitles;
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
    final hasEpName = epName.isNotEmpty &&
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
                                style: AppText.headline
                                    .copyWith(color: Colors.white),
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
                              style: AppText.caption
                                  .copyWith(color: Colors.white70),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Sleep timer + lock (top-right). Zoom is in the bottom row.
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
                    icon: const Icon(Icons.lock_open_rounded,
                        color: Colors.white),
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
                  // Button row.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ControlButton(
                        icon: Icons.speed,
                        label: 'Speed',
                        onTap: onSpeed,
                      ),
                      if (c.categories.length > 1 ||
                          c.audioKinds.length > 1 ||
                          c.mediaAudioTracks.length > 1)
                        _ControlButton(
                          icon: Icons.graphic_eq,
                          label: 'Audio',
                          onTap: onAudio,
                        ),
                      _ControlButton(
                        icon: Icons.closed_caption,
                        label: 'Subtitles',
                        onTap: onSubtitles,
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
                      if (onEpisodes != null)
                        _ControlButton(
                          icon: Icons.video_library_outlined,
                          label: 'Episodes',
                          onTap: onEpisodes!,
                        ),
                      if (onPrev != null)
                        _ControlButton(
                          icon: Icons.skip_previous,
                          label: 'Previous',
                          onTap: onPrev!,
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

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
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
                          setState(() => _dragMs = v);
                          widget.onInteract();
                        },
                  onChanged: totalMs <= 0
                      ? null
                      : (v) {
                          setState(() => _dragMs = v);
                          widget.onInteract();
                        },
                  onChangeEnd: totalMs <= 0
                      ? null
                      : (v) {
                          widget.controller
                              .seekTo(Duration(milliseconds: v.round()));
                          setState(() => _dragMs = null);
                          widget.onInteract();
                        },
                ),
              ),
            ),
            Text(
              _fmt(widget.duration),
              style: AppText.caption.copyWith(color: Colors.white),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small bits.
// ─────────────────────────────────────────────────────────────────────────────

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

  /// Optional trailing icon (e.g. upload for "Load from file…"). The leading
  /// slot stays reserved for the coral active-check.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: active
          ? const Icon(Icons.check, color: AppColors.accent, size: 20)
          : const SizedBox(width: 20),
      title: Text(
        label,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
      ),
      trailing: icon == null
          ? null
          : Icon(icon, color: AppColors.textSecondary, size: 20),
      onTap: onTap,
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
            icon: const Icon(Icons.restart_alt_rounded,
                color: AppColors.textSecondary, size: 20),
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
