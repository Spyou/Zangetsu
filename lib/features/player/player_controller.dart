import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';

/// Owns a media_kit [Player] for one watch session: opens a source with its
/// headers + subtitles, persists resume position, advances on completion, and
/// falls through to the next source if one fails to start (covers dead/DRM
/// sources).
class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.sourceId,
    required this.episodes,
    required this.resume,
    required Future<List<VideoSource>> Function(String episodeUrl) resolveSources,
  }) : _resolveSources = resolveSources;

  final String sourceId;
  final List<Episode> episodes;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) _resolveSources;

  final Player player = Player();
  late final VideoController videoController = VideoController(player);

  int currentIndex = 0;
  List<VideoSource> sources = const [];
  VideoSource? active;
  String? error;
  bool loadingSources = false;

  final List<StreamSubscription> _subs = [];
  Duration _lastPos = Duration.zero;
  Duration _lastDur = Duration.zero;

  Episode get currentEpisode => episodes[currentIndex];

  void init(int index) {
    _subs.add(player.stream.position.listen((p) => _lastPos = p));
    _subs.add(player.stream.duration.listen((d) => _lastDur = d));
    _subs.add(player.stream.completed.listen((done) {
      if (done) playNext();
    }));
    _subs.add(player.stream.error.listen((e) => _onPlaybackError(e)));
    openEpisode(index);
  }

  /// Resolves sources for [index] and starts the best one.
  Future<void> openEpisode(int index) async {
    await _persist();
    currentIndex = index;
    error = null;
    loadingSources = true;
    sources = const [];
    active = null;
    notifyListeners();
    try {
      final resolved = await _resolveSources(currentEpisode.url);
      sources = resolved;
      loadingSources = false;
      final pick = pickDefault(resolved);
      if (pick == null) {
        error = 'No playable sources for this episode.';
        notifyListeners();
        return;
      }
      await _open(pick);
    } catch (e) {
      loadingSources = false;
      error = 'Could not load sources: $e';
      notifyListeners();
    }
  }

  /// Switch to a specific source (sub/dub or quality change), preserving position.
  Future<void> switchSource(VideoSource s) => _open(s, seekTo: _lastPos);

  Future<void> _open(VideoSource s, {Duration? seekTo}) async {
    active = s;
    error = null;
    notifyListeners();
    final mark = resume.get(sourceId, currentEpisode.id);
    final start = seekTo ??
        ((mark != null && !mark.finished) ? mark.position : Duration.zero);
    await player.open(
      Media(s.url, httpHeaders: s.headers, start: start > Duration.zero ? start : null),
    );
    // Attach the first soft subtitle, if any.
    if (s.subtitles.isNotEmpty) {
      final sub = s.subtitles.firstWhere((x) => x.isDefault, orElse: () => s.subtitles.first);
      await player.setSubtitleTrack(
          SubtitleTrack.uri(sub.url, title: sub.label ?? sub.lang, language: sub.lang));
    }
  }

  /// Try the next source after the [failed] one (dead/DRM/unsupported).
  Future<void> _onPlaybackError(String e) async {
    debugPrint('[player] error: $e');
    final remaining = sources.where((s) => s != active).toList();
    final next = pickDefault(remaining);
    if (next != null) {
      await _open(next);
    } else {
      error = 'Playback failed: $e';
      notifyListeners();
    }
  }

  Future<void> playNext() async {
    if (currentIndex + 1 < episodes.length) {
      await openEpisode(currentIndex + 1);
    }
  }

  Future<void> _persist() async {
    if (_lastDur > Duration.zero) {
      await resume.save(sourceId, currentEpisode.id, _lastPos, _lastDur);
    }
  }

  @override
  void dispose() {
    _persist();
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}
