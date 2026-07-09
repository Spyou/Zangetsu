import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_keys.dart';
import 'tv_exo_controller.dart';

/// TV ExoPlayer player (SP1a core: play/pause, D-pad seek, resume, next/prev).
/// Constructor mirrors PlayerScreen so the SP1d router can swap it in unchanged.
/// Reached only behind the EXO_SPIKE dev flag until SP1d.
class TvExoPlayerScreen extends StatefulWidget {
  const TvExoPlayerScreen({
    super.key,
    required this.sourceId,
    required this.resume,
    required this.resolveSources,
    this.episodes = const [],
    this.startIndex = 0,
    this.showUrl,
    this.showTitle,
    this.category = 'sub',
  });

  final String sourceId;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;
  final List<Episode> episodes;
  final int startIndex;
  final String? showUrl;
  final String? showTitle;
  final String category;

  @override
  State<TvExoPlayerScreen> createState() => _TvExoPlayerScreenState();
}

class _TvExoPlayerScreenState extends State<TvExoPlayerScreen> {
  TvExoController? _c;
  int _index = 0;
  bool _resumeSeeked = false;
  String? _error;
  int _lastSavedMs = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.episodes.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.episodes.length - 1);
  }

  Episode? get _ep =>
      widget.episodes.isEmpty ? null : widget.episodes[_index];

  String get _resumeShowId => widget.showUrl ?? widget.sourceId;

  void _onViewCreated(int id) {
    final c = TvExoController(id);
    _c = c;
    c.duration.addListener(_maybeResumeSeek);
    c.position.addListener(_maybeSaveProgress);
    c.ended.addListener(_onEnded);
    _loadEpisode();
  }

  Future<void> _loadEpisode() async {
    final ep = _ep;
    if (ep == null) {
      setState(() => _error = 'No episode to play.');
      return;
    }
    _resumeSeeked = false;
    _lastSavedMs = 0;
    try {
      final sources = await widget.resolveSources(ep.url);
      final prefer = widget.category == 'dub' ? AudioKind.dub : AudioKind.sub;
      final src = pickDefault(sources, prefer: prefer);
      if (src == null) {
        setState(() => _error = 'No playable source.');
        return;
      }
      await _c?.setSource(src.url, src.headers ?? const {});
    } catch (e) {
      setState(() => _error = 'Could not load this episode.');
    }
  }

  void _maybeResumeSeek() {
    final c = _c;
    if (c == null) return;
    final mark = c.duration.value > 0
        ? widget.resume.get(widget.sourceId, _resumeShowId, _ep?.id ?? '')
        : null;
    final resumeMs = mark?.position.inMilliseconds ?? 0;
    if (TvExoController.shouldResumeSeek(
      resumeMs: resumeMs,
      durationMs: c.duration.value,
      alreadySeeked: _resumeSeeked,
    )) {
      _resumeSeeked = true;
      c.seek(resumeMs);
    }
  }

  void _maybeSaveProgress() {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || c.duration.value <= 0) return;
    final pos = c.position.value;
    if ((pos - _lastSavedMs).abs() < 5000) return; // throttle: every 5s
    _lastSavedMs = pos;
    widget.resume.save(
      widget.sourceId,
      _resumeShowId,
      ep.id,
      Duration(milliseconds: pos),
      Duration(milliseconds: c.duration.value),
    );
  }

  void _onEnded() {
    if (_c?.ended.value == true) _next();
  }

  void _next() {
    if (_index >= widget.episodes.length - 1) return;
    setState(() => _index++);
    _loadEpisode();
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() => _index--);
    _loadEpisode();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    c.playing.value ? c.pause() : c.play();
  }

  void _seekBy(int deltaMs) {
    final c = _c;
    if (c == null) return;
    final target =
        (c.position.value + deltaMs).clamp(0, c.duration.value == 0 ? 1 << 31 : c.duration.value);
    c.seek(target);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (okKeys.contains(k)) { _togglePlay(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowRight) { _seekBy(10000); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowLeft) { _seekBy(-10000); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.mediaTrackNext) { _next(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) { _prev(); return KeyEventResult.handled; }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    final c = _c;
    if (c != null) {
      // Persist final position before releasing.
      final ep = _ep;
      if (ep != null && c.duration.value > 0) {
        widget.resume.save(
          widget.sourceId,
          _resumeShowId,
          ep.id,
          Duration(milliseconds: c.position.value),
          Duration(milliseconds: c.duration.value),
        );
      }
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: PlatformViewLink(
                viewType: 'zangetsu/exoplayer_view',
                surfaceFactory: (context, controller) => AndroidViewSurface(
                  controller: controller as AndroidViewController,
                  gestureRecognizers:
                      const <Factory<OneSequenceGestureRecognizer>>{},
                  hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                ),
                onCreatePlatformView: (params) {
                  final controller = PlatformViewsService.initExpensiveAndroidView(
                    id: params.id,
                    viewType: 'zangetsu/exoplayer_view',
                    layoutDirection: TextDirection.ltr,
                    creationParams: const <String, dynamic>{},
                    creationParamsCodec: const StandardMessageCodec(),
                    onFocus: () => params.onFocusChanged(true),
                  )
                    ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
                    ..addOnPlatformViewCreatedListener(_onViewCreated)
                    ..create();
                  return controller;
                },
              ),
            ),
            if (_error != null)
              Center(
                child: Text(_error!,
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
              ),
            if (_c != null) _controlsOverlay(_c!),
          ],
        ),
      ),
    );
  }

  Widget _controlsOverlay(TvExoController c) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 28),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Scrubber
            ValueListenableBuilder<int>(
              valueListenable: c.position,
              builder: (_, pos, _) => ValueListenableBuilder<int>(
                valueListenable: c.duration,
                builder: (_, dur, _) {
                  final frac = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
                  return Row(
                    children: [
                      Text(_fmt(pos),
                          style: const TextStyle(color: Colors.white70)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: frac,
                          minHeight: 4,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation(AppColors.accent),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(_fmt(dur),
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: c.buffering,
                  builder: (_, buf, _) => buf
                      ? const Padding(
                          padding: EdgeInsets.only(right: 16),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: c.playing,
                  builder: (_, playing, _) => Text(
                    playing ? 'Playing — OK to pause' : 'Paused — OK to play',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    final m = s ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }
}
