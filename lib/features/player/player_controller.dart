import 'dart:async';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/hls.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';

/// Immutable view-state for the player screen: exactly the fields the UI
/// rebuilds on. These used to drive `notifyListeners()` on the old
/// `ChangeNotifier`; they are now emitted by [PlayerCubit].
///
/// Live playback values (position/playing/buffering/duration) are NOT here —
/// the screen still binds those directly off `player.stream.*` so the engine
/// behaviour is untouched.
class PlayerState extends Equatable {
  const PlayerState({
    this.loadingSources = false,
    this.error,
    this.sources = const [],
    this.active,
    this.qualities = const [],
    this.activeQuality,
    this.currentIndex = 0,
    this.tracks = const Tracks(),
  });

  /// True while sources for the current episode are being resolved.
  final bool loadingSources;

  /// Non-null when sources couldn't be resolved/played (drives the retry UI).
  final String? error;

  /// Resolved sources for the current episode.
  final List<VideoSource> sources;

  /// The source currently opened in the engine.
  final VideoSource? active;

  /// HLS-master quality variants (empty unless a multi-variant master exists).
  final List<HlsVariant> qualities;

  /// Selected HLS variant; null = Auto (the adaptive master).
  final HlsVariant? activeQuality;

  /// Index into the episode list of the currently-open episode.
  final int currentIndex;

  /// Available audio/sub/video tracks for the open media (driven by
  /// `player.stream.tracks`).
  final Tracks tracks;

  PlayerState copyWith({
    bool? loadingSources,
    String? Function()? error,
    List<VideoSource>? sources,
    VideoSource? Function()? active,
    List<HlsVariant>? qualities,
    HlsVariant? Function()? activeQuality,
    int? currentIndex,
    Tracks? tracks,
  }) =>
      PlayerState(
        loadingSources: loadingSources ?? this.loadingSources,
        error: error != null ? error() : this.error,
        sources: sources ?? this.sources,
        active: active != null ? active() : this.active,
        qualities: qualities ?? this.qualities,
        activeQuality: activeQuality != null ? activeQuality() : this.activeQuality,
        currentIndex: currentIndex ?? this.currentIndex,
        tracks: tracks ?? this.tracks,
      );

  @override
  List<Object?> get props =>
      [loadingSources, error, sources, active, qualities, activeQuality, currentIndex, tracks];
}

/// Owns a media_kit [Player] for one watch session: opens a source with its
/// headers + subtitles, persists resume position, advances on completion, and
/// falls through to the next source if one fails to start (covers dead/DRM
/// sources).
class PlayerCubit extends Cubit<PlayerState> {
  PlayerCubit({
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
    this.availableCategories = const [],
  })  : _resolveSources = resolveSources,
        _dio = dio,
        _activeCategory = category ?? 'sub',
        super(const PlayerState());

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

  /// The category (sub/dub) the session launched in. The LIVE category (which
  /// the user can flip mid-session) is [_activeCategory] — `category` is just
  /// the launch value.
  final String? category;

  /// Sub/Dub categories this title offers (e.g. `['sub','dub']`). When length
  /// <= 1 the player treats the source as single-category (no Version switch).
  /// AllAnime sub/dub are DIFFERENT streams — switching re-resolves the OTHER
  /// category's URL for the current episode (see [_episodeUrl]).
  final List<String> availableCategories;

  /// The currently-playing category. Re-resolving sources rewrites the
  /// episode URL's `/sub/` ↔ `/dub/` segment to this. Persisted per-title.
  String _activeCategory;

  final Player player = Player();
  late final VideoController videoController = VideoController(player);

  VideoSource? _hlsMaster; // the HLS master among `sources` that the quality menu expands

  final List<StreamSubscription> _subs = [];
  Duration _lastPos = Duration.zero;
  Duration _lastDur = Duration.zero;
  int _lastHistoryMs = 0; // throttle: last wall-clock ms we wrote progress
  int _gen = 0; // bumped per open; async continuations bail if superseded
  final Set<String> _tried = {}; // source URLs already attempted this episode
  bool _recovering = false; // debounce: one error-recovery at a time

  Episode get currentEpisode => episodes[state.currentIndex];

  /// The episode URL to resolve sources from, rewritten to the active
  /// category. Sub/Dub are separate AllAnime streams encoded in the URL
  /// (`allanime://<id>/sub/<n>` vs `.../dub/<n>`), so switching language means
  /// resolving the OTHER category's URL. Only rewrites when the title offers
  /// more than one category AND the URL carries a `/sub/` or `/dub/` segment
  /// (NetMirror etc. have no such segment → unchanged).
  String _episodeUrl(Episode ep) {
    if (availableCategories.length > 1 &&
        RegExp(r'/(sub|dub)/').hasMatch(ep.url)) {
      return ep.url.replaceFirst(RegExp(r'/(sub|dub)/'), '/$_activeCategory/');
    }
    return ep.url;
  }

  // ── Sub/Dub (category) switching — the player owns this now (not Detail) ──

  /// Categories this title offers (drives the player's "Version" section).
  List<String> get categories => availableCategories;

  /// The currently-active category ('sub'/'dub').
  String get activeCategory => _activeCategory;

  /// Switch the whole session to [cat] (sub ↔ dub). No-op when unchanged or
  /// not offered. Re-resolves the CURRENT episode in the new language while
  /// preserving the live position and current index, persists the per-title
  /// choice, and keeps the rest of the session (incl. playNext) + history in
  /// [cat].
  Future<void> switchCategory(String cat) async {
    if (cat == _activeCategory || !availableCategories.contains(cat)) return;
    _activeCategory = cat;
    await sl<TitlePrefsStore>().setCategory(sourceId, showUrl ?? '', cat);

    // Re-resolve the current episode in the new language — like openEpisode but
    // keeping currentIndex and the live position.
    final gen = ++_gen;
    final keepPos = _lastPos;
    _tried.clear();
    _recovering = false;
    emit(state.copyWith(
      error: () => null,
      loadingSources: true,
      sources: const [],
      active: () => null,
    ));
    try {
      final resolved = await _resolveSources(_episodeUrl(currentEpisode));
      if (gen != _gen) return;
      emit(state.copyWith(sources: resolved, loadingSources: false));
      _buildQualityMenu(gen);
      final pick = pickDefault(resolved);
      if (pick == null) {
        emit(state.copyWith(
            error: () => 'No playable sources for this episode.'));
        return;
      }
      await _open(pick, seekTo: keepPos, gen: gen);
    } catch (e) {
      if (gen != _gen) return;
      emit(state.copyWith(
        loadingSources: false,
        error: () => 'Could not load sources: $e',
      ));
    }
  }

  void init(int index) {
    emit(state.copyWith(tracks: player.state.tracks));
    _subs.add(player.stream.tracks.listen((t) {
      emit(state.copyWith(tracks: t));
    }));
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

  List<AudioKind> get audioKinds => availableKinds(state.sources);
  AudioKind? get activeKind => state.active?.kind;

  /// Switch to the best source of the given audio [k] (Sub/Dub), preserving
  /// the live position.
  Future<void> switchAudio(AudioKind k) async {
    final s = pickDefault(state.sources, prefer: k);
    if (s != null) await switchSource(s);
  }

  // ── Embedded/soft track selection (CloudStream-style picker) ──────────────
  // Tracks populate after a media opens (driven by player.stream.tracks).

  /// Embedded audio tracks for the open media (excludes the synthetic
  /// auto/no entries media_kit always reports).
  List<AudioTrack> get mediaAudioTracks =>
      state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();

  /// Embedded subtitle tracks for the open media (excludes auto/no).
  List<SubtitleTrack> get mediaSubtitleTracks =>
      state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();

  /// Currently-selected audio track (id == 'auto'/'no' for the synthetic ones).
  AudioTrack get activeAudioTrack => player.state.track.audio;

  /// Currently-selected subtitle track (id == 'no' when subs are off).
  SubtitleTrack get activeSubtitleTrack => player.state.track.subtitle;

  void setAudioTrack(AudioTrack t) => player.setAudioTrack(t);
  void setSubtitle(SubtitleTrack t) => player.setSubtitleTrack(t);
  void subtitlesOff() => player.setSubtitleTrack(SubtitleTrack.no());

  /// External "soft" subtitles advertised by the active source.
  List<Subtitle> get softSubs => state.active?.subtitles ?? const [];

  /// Load one of the source's soft-subs by URL.
  Future<void> setSoftSub(Subtitle s) async => player.setSubtitleTrack(
      SubtitleTrack.uri(s.url, title: s.label ?? s.lang, language: s.lang));

  /// Load an external subtitle file from disk (picked via file_picker).
  Future<void> setSubtitleFromFile(String path) async =>
      player.setSubtitleTrack(SubtitleTrack.uri(path));

  // TODO(player): defer online subtitle search/download, full subtitle
  // styling, and subtitle delay/sync (CloudStream parity, post-v1).

  /// Resolves sources for [index] and starts the best one.
  Future<void> openEpisode(int index) async {
    final gen = ++_gen;
    await _persist();
    _tried.clear();
    _recovering = false;
    emit(state.copyWith(
      currentIndex: index,
      error: () => null,
      loadingSources: true,
      sources: const [],
      active: () => null,
    ));
    try {
      final resolved = await _resolveSources(_episodeUrl(currentEpisode));
      if (gen != _gen) return; // superseded by a newer open
      emit(state.copyWith(sources: resolved, loadingSources: false));
      _buildQualityMenu(gen); // populate Auto/1080p/720p from the HLS master, if any
      final pick = pickDefault(resolved);
      if (pick == null) {
        emit(state.copyWith(error: () => 'No playable sources for this episode.'));
        return;
      }
      await _open(pick, gen: gen);
    } catch (e) {
      if (gen != _gen) return;
      emit(state.copyWith(
        loadingSources: false,
        error: () => 'Could not load sources: $e',
      ));
    }
  }

  /// Switch to a specific source (sub/dub or quality change), preserving position.
  Future<void> switchSource(VideoSource s) => _open(s, seekTo: _lastPos);

  /// Builds the quality menu from the first HLS master among `state.sources`
  /// (independent of which source plays by default). Fire-and-forget; the menu
  /// appears once the master is fetched + parsed. Resets prior quality state.
  void _buildQualityMenu(int gen) {
    emit(state.copyWith(qualities: const [], activeQuality: () => null));
    _hlsMaster = null;
    VideoSource? master;
    for (final s in state.sources) {
      if (s.container == SourceContainer.hls) { master = s; break; }
    }
    if (master == null) return;
    _hlsMaster = master;
    final m = master;
    fetchHlsVariants(m.url, m.headers, _dio).then((vs) {
      if (gen == _gen && vs.length > 1) {
        emit(state.copyWith(qualities: vs));
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
    emit(state.copyWith(activeQuality: () => v));
  }

  // ── Source-based quality (when there's no multi-variant HLS master) ───────
  // AllAnime etc. return several distinct sources that each carry a resolution
  // label but no HLS master playlist, so [qualities] is empty. Surface those
  // per-source qualities as selectable options instead.

  /// Distinct non-empty quality labels among the resolved sources for the
  /// active audio kind, high→low.
  List<String> get sourceQualities {
    final kind = state.active?.kind;
    final seen = <String>{};
    final out = <String>[];
    for (final s in sortByQuality(state.sources)) {
      if (kind != null && s.kind != kind) continue;
      final q = (s.quality ?? '').trim();
      if (q.isEmpty || seen.contains(q)) continue;
      seen.add(q);
      out.add(q);
    }
    return out;
  }

  /// The quality label of the currently-playing source (for the active check).
  String? get activeSourceQuality => (state.active?.quality ?? '').trim().isEmpty
      ? null
      : state.active!.quality!.trim();

  /// Switch to the best source matching quality label [q] (same audio kind),
  /// preserving the live position.
  Future<void> selectSourceQuality(String q) async {
    final kind = state.active?.kind;
    for (final s in sortByQuality(state.sources)) {
      if ((s.quality ?? '').trim() == q && (kind == null || s.kind == kind)) {
        await switchSource(s);
        return;
      }
    }
  }

  Future<void> _open(VideoSource s, {Duration? seekTo, int? gen}) async {
    final g = gen ?? ++_gen;
    emit(state.copyWith(active: () => s, error: () => null));
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
    final failed = state.active;
    if (failed != null) _tried.add(failed.url);
    // Never re-try a source we've already attempted this episode (prevents the
    // A→B→A thrash cascade).
    final remaining = state.sources.where((s) => !_tried.contains(s.url)).toList();
    final next = pickDefault(remaining, prefer: failed?.kind ?? AudioKind.sub);
    if (next != null) {
      await _open(next, seekTo: _lastPos);
    } else {
      emit(state.copyWith(
        error: () => 'No source could be played on this device (tried ${_tried.length}).',
      ));
    }
    _recovering = false;
  }

  Future<void> playNext() async {
    if (state.currentIndex + 1 < episodes.length) {
      await openEpisode(state.currentIndex + 1);
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
        category: _activeCategory,
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
  Future<void> close() async {
    await _persist();
    for (final s in _subs) {
      s.cancel();
    }
    await player.dispose();
    return super.close();
  }
}
