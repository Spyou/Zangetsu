import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/filler_service.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'player_tv_controls.dart';

/// Apple TV playback via AVPlayer ([video_player] + [video_player_tvos]).
///
/// Replaces Android TV's [TvNativePlayer] / [TvExoPlayerScreen] on tvOS.
/// D-pad chrome is the shared [PlayerTvControls] overlay.
class TvAvPlayerScreen extends StatefulWidget {
  const TvAvPlayerScreen({
    super.key,
    required this.sourceId,
    required this.resume,
    required this.resolveSources,
    this.episodes = const [],
    this.startIndex = 0,
    this.showUrl,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.category = 'sub',
    this.malId,
  });

  final String sourceId;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;
  final List<Episode> episodes;
  final int startIndex;
  final String? showUrl;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String category;
  final int? malId;

  @override
  State<TvAvPlayerScreen> createState() => _TvAvPlayerScreenState();
}

class _TvAvPlayerScreenState extends State<TvAvPlayerScreen> {
  VideoPlayerController? _c;
  int _index = 0;
  bool _loading = true;
  String? _error;
  bool _barVisible = true;
  List<VideoSource> _sources = const [];
  VideoSource? _active;
  Timer? _saveTimer;
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _isPlaying = false;
  Set<int> _fillerEps = const {};

  String get _showId => widget.showUrl ?? widget.sourceId;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    WakelockPlus.enable();
    _ensureFiller();
    _open(_index);
    _saveTimer = Timer.periodic(const Duration(seconds: 8), (_) => _save());
  }

  void _ensureFiller() {
    final id = widget.malId;
    if (id == null) return;
    FillerService.instance.fillerEpisodes(id).then((s) {
      if (mounted) _fillerEps = s;
    });
  }

  @override
  void dispose() {
    _save();
    _saveTimer?.cancel();
    _playing.close();
    _position.close();
    _duration.close();
    _c?.removeListener(_onTick);
    _c?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void _onTick() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    _pos = c.value.position;
    _dur = c.value.duration;
    _isPlaying = c.value.isPlaying;
    if (!_playing.isClosed) _playing.add(_isPlaying);
    if (!_position.isClosed) _position.add(_pos);
    if (!_duration.isClosed) _duration.add(_dur);
    if (c.value.position >= c.value.duration &&
        c.value.duration > Duration.zero) {
      _playNext(auto: true);
    }
  }

  Future<void> _open(int index, {VideoSource? preferred}) async {
    if (index < 0 || index >= widget.episodes.length) return;
    setState(() {
      _loading = true;
      _error = null;
      _index = index;
    });
    _c?.removeListener(_onTick);
    await _c?.dispose();
    _c = null;

    try {
      _sources = await widget.resolveSources(widget.episodes[index].url);
      if (_sources.isEmpty) {
        setState(() {
          _error = 'No playable sources';
          _loading = false;
        });
        return;
      }
      final src = preferred ?? _sources.first;
      _active = src;
      final uri = Uri.tryParse(src.url);
      final isFile = uri == null ||
          uri.scheme.isEmpty ||
          uri.scheme == 'file' ||
          !src.url.contains('://');
      final controller = isFile
          ? VideoPlayerController.file(File(src.url))
          : VideoPlayerController.networkUrl(
              Uri.parse(src.url),
              httpHeaders: src.headers ?? const {},
            );
      await controller.initialize();
      final mark = widget.resume.get(
        widget.sourceId,
        _showId,
        widget.episodes[index].id,
      );
      if (mark != null &&
          mark.position > const Duration(seconds: 3) &&
          !mark.finished) {
        await controller.seekTo(mark.position);
      }
      controller.addListener(_onTick);
      await controller.play();
      _c = controller;
      _onTick();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _save() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position;
    final dur = c.value.duration;
    if (dur <= Duration.zero || pos <= Duration.zero) return;
    final ep = widget.episodes[_index];
    widget.resume.save(widget.sourceId, _showId, ep.id, pos, dur);
    if (!sl.isRegistered<WatchHistory>()) return;
    sl<WatchHistory>().save(
      HistoryEntry(
        sourceId: widget.sourceId,
        showId: _showId,
        showTitle: widget.showTitle ?? '',
        cover: widget.cover,
        coverHeaders: widget.coverHeaders,
        showUrl: widget.showUrl ?? '',
        category: widget.category,
        episodeId: ep.id,
        episodeNumber: ep.number,
        episodeUrl: ep.url,
        position: pos,
        duration: dur,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        malId: widget.malId,
      ),
      flush: true,
    );
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  Future<void> _seekBy(Duration d) async {
    final c = _c;
    if (c == null) return;
    var next = c.value.position + d;
    if (next < Duration.zero) next = Duration.zero;
    final dur = c.value.duration;
    if (dur > Duration.zero && next > dur) next = dur;
    await c.seekTo(next);
  }

  void _playNext({bool auto = false}) {
    final target = nextAutoplayIndex(
      currentIndex: _index,
      episodes: widget.episodes,
      fillerEps: _fillerEps,
      autoSkipFiller: auto && sl<PlaybackPrefs>().autoSkipFiller,
    );
    if (target == null) return;
    _save();
    _open(target);
  }

  void _setSpeed(double speed) {
    _c?.setPlaybackSpeed(speed);
  }

  void _pickSource() {
    if (_sources.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Sources'),
        children: [
          for (final s in _sources)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(ctx);
                _open(_index, preferred: s);
              },
              child: Text(
                s.label ?? s.quality ?? s.url,
                style: TextStyle(
                  color: s.url == _active?.url ? AppColors.accent : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_c != null && _c!.value.isInitialized)
            Center(
              child: AspectRatio(
                aspectRatio: _c!.value.aspectRatio == 0
                    ? 16 / 9
                    : _c!.value.aspectRatio,
                child: VideoPlayer(_c!),
              ),
            ),
          if (_loading)
            const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _error!,
                  style: AppText.body.copyWith(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (!_loading && _error == null && _c != null)
            PlayerTvControls(
              onTogglePlay: _togglePlay,
              onSeekBy: _seekBy,
              onSpeed: () => _setSpeed(
                (_c?.value.playbackSpeed ?? 1) == 1 ? 1.5 : 1,
              ),
              onAudioSubs: () {},
              onQuality: () {},
              onSources: _pickSource,
              onFit: () {},
              onBack: () => Navigator.of(context).maybePop(),
              onNext: _index + 1 < widget.episodes.length ? _playNext : null,
              playingStream: _playing.stream,
              initialPlaying: _isPlaying,
              barVisible: _barVisible,
              onBarChange: (v) => setState(() => _barVisible = v),
              positionStream: _position.stream,
              durationStream: _duration.stream,
              initialPosition: _pos,
              initialDuration: _dur,
              skipInfoFor: (_) => null,
            ),
        ],
      ),
    );
  }
}
