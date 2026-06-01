import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/hls.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/watch_history.dart';

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
    required Dio dio,
    this.history,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.showUrl,
    this.category,
  }) : _resolveSources = resolveSources, _dio = dio;

  final String sourceId;
  final List<Episode> episodes;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) _resolveSources;
  final Dio _dio;

  // Optional show-context for writing the Continue Watching history feed.
  final WatchHistory? history;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String? showUrl;
  final String? category;

  final Player player = Player();
  late final VideoController videoController = VideoController(player);

  int currentIndex = 0;
  List<VideoSource> sources = const [];
  VideoSource? active;
  List<HlsVariant> qualities = const [];
  HlsVariant? activeQuality; // null = Auto (the master)
  VideoSource? _hlsMaster; // the HLS master among `sources` that the quality menu expands
  String? error;
  bool loadingSources = false;

  final List<StreamSubscription> _subs = [];
  Duration _lastPos = Duration.zero;
  Duration _lastDur = Duration.zero;
  int _lastHistoryMs = 0; // throttle: last wall-clock ms we wrote progress
  int _gen = 0; // bumped per open; async continuations bail if superseded
  final Set<String> _tried = {}; // source URLs already attempted this episode
  bool _recovering = false; // debounce: one error-recovery at a time

  Episode get currentEpisode => episodes[currentIndex];

  void init(int index) {
    _subs.add(player.stream.position.listen((p) {
      _lastPos = p;
      // Throttled progress capture so Continue Watching fills mid-episode
      // (without waiting for an episode switch / dispose). Cheap: at most
      // one write every ~5s, only while we have a real duration.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_lastDur > Duration.zero && now - _lastHistoryMs >= 5000) {
        _lastHistoryMs = now;
        _persist();
      }
    }));
    _subs.add(player.stream.duration.listen((d) => _lastDur = d));
    _subs.add(player.stream.completed.listen((done) {
      if (done) playNext();
    }));
    _subs.add(player.stream.error.listen((e) => _onPlaybackError(e)));
    openEpisode(index);
  }

  // ── Public playback helpers (used by the Netflix-style overlay) ───────────

  void setRate(double r) => player.setRate(r);
  void togglePlay() => player.playOrPause();
  void seekTo(Duration d) => player.seek(d);

  /// Seek by [delta] (signed), clamped into 0..duration.
  void seekBy(Duration delta) {
    final target = _lastPos + delta;
    final dur = _lastDur;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    player.seek(clamped);
  }

  List<AudioKind> get audioKinds => availableKinds(sources);
  AudioKind? get activeKind => active?.kind;

  /// Switch to the best source of the given audio [k] (Sub/Dub), preserving
  /// the live position.
  Future<void> switchAudio(AudioKind k) async {
    final s = pickDefault(sources, prefer: k);
    if (s != null) await switchSource(s);
  }

  /// Resolves sources for [index] and starts the best one.
  Future<void> openEpisode(int index) async {
    final gen = ++_gen;
    await _persist();
    currentIndex = index;
    _tried.clear();
    _recovering = false;
    error = null;
    loadingSources = true;
    sources = const [];
    active = null;
    notifyListeners();
    try {
      final resolved = await _resolveSources(currentEpisode.url);
      if (gen != _gen) return; // superseded by a newer open
      sources = resolved;
      loadingSources = false;
      _buildQualityMenu(gen); // populate Auto/1080p/720p from the HLS master, if any
      final pick = pickDefault(resolved);
      if (pick == null) {
        error = 'No playable sources for this episode.';
        notifyListeners();
        return;
      }
      await _open(pick, gen: gen);
    } catch (e) {
      if (gen != _gen) return;
      loadingSources = false;
      error = 'Could not load sources: $e';
      notifyListeners();
    }
  }

  /// Switch to a specific source (sub/dub or quality change), preserving position.
  Future<void> switchSource(VideoSource s) => _open(s, seekTo: _lastPos);

  /// Builds the quality menu from the first HLS master among [sources]
  /// (independent of which source plays by default). Fire-and-forget; the menu
  /// appears once the master is fetched + parsed. Resets prior quality state.
  void _buildQualityMenu(int gen) {
    qualities = const [];
    activeQuality = null;
    _hlsMaster = null;
    VideoSource? master;
    for (final s in sources) {
      if (s.container == SourceContainer.hls) { master = s; break; }
    }
    if (master == null) return;
    _hlsMaster = master;
    final m = master;
    fetchHlsVariants(m.url, m.headers, _dio).then((vs) {
      if (gen == _gen && vs.length > 1) {
        qualities = vs;
        notifyListeners();
      }
    });
  }

  /// Switch the HLS resolution. [v] == null → Auto (the adaptive master);
  /// otherwise the chosen variant. Plays via the HLS master's headers/kind and
  /// resumes at the live position. No-op if there's no HLS master.
  Future<void> selectQuality(HlsVariant? v) async {
    final master = _hlsMaster;
    if (master == null) return;
    final url = v?.url ?? master.url;
    await _open(
      VideoSource(
        url: url, quality: v?.quality ?? 'auto', container: SourceContainer.hls,
        headers: master.headers, kind: master.kind,
        audioLang: master.audioLang, subtitles: master.subtitles,
      ),
      seekTo: _lastPos,
    );
    activeQuality = v;
    notifyListeners();
  }

  Future<void> _open(VideoSource s, {Duration? seekTo, int? gen}) async {
    final g = gen ?? ++_gen;
    active = s;
    error = null;
    notifyListeners();
    final mark = resume.get(sourceId, currentEpisode.id);
    final start = seekTo ??
        ((mark != null && !mark.finished) ? mark.position : Duration.zero);
    await player.open(
      Media(s.url, httpHeaders: s.headers, start: start > Duration.zero ? start : null),
    );
    if (g != _gen) return; // superseded mid-open
    if (s.subtitles.isNotEmpty) {
      final sub = s.subtitles.firstWhere((x) => x.isDefault, orElse: () => s.subtitles.first);
      await player.setSubtitleTrack(
          SubtitleTrack.uri(sub.url, title: sub.label ?? sub.lang, language: sub.lang));
    }
  }

  /// Try the next source after the current one fails (dead/DRM/unsupported),
  /// preserving the live position and the audio kind.
  Future<void> _onPlaybackError(String e) async {
    debugPrint('[player] error: $e');
    final lower = e.toLowerCase();
    // libmpv emits many non-fatal warnings (e.g. the iOS Simulator has no
    // audio device). Only treat clear "this stream is unplayable" errors as a
    // reason to switch sources — never the audio-device/no-sound warnings.
    final fatal = lower.contains('failed to open') ||
        lower.contains('recognize file format') ||
        lower.contains('ffurl') ||
        lower.contains('connection');
    if (!fatal || _recovering) return;
    _recovering = true;
    final failed = active;
    if (failed != null) _tried.add(failed.url);
    // Never re-try a source we've already attempted this episode (prevents the
    // A→B→A thrash cascade).
    final remaining = sources.where((s) => !_tried.contains(s.url)).toList();
    final next = pickDefault(remaining, prefer: failed?.kind ?? AudioKind.sub);
    if (next != null) {
      await _open(next, seekTo: _lastPos);
    } else {
      error = 'No source could be played on this device (tried ${_tried.length}).';
      notifyListeners();
    }
    _recovering = false;
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
    final h = history;
    final title = showTitle;
    if (h != null && title != null && _lastDur > Duration.zero) {
      await h.save(HistoryEntry(
        sourceId: sourceId,
        showId: showUrl ?? sourceId,
        showTitle: title,
        cover: cover,
        coverHeaders: coverHeaders,
        showUrl: showUrl ?? '',
        category: category ?? 'sub',
        episodeId: currentEpisode.id,
        episodeNumber: currentEpisode.number,
        episodeUrl: currentEpisode.url,
        position: _lastPos,
        duration: _lastDur,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
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
