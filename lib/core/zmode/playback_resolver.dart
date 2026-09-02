import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/video_source.dart';
import '../playback/source_health_store.dart';
import '../provider/cf_solve_needed.dart';
import '../repository/source_repository.dart';
import 'match_store.dart';
import 'source_matcher.dart';
import 'zmode_ids.dart';
import 'zmode_source_prefs.dart';

/// Thrown when no installed source can play this metadata episode — either
/// because no source has the title, the episode is missing everywhere, or
/// every source that has it returned no streams.
class EpisodeNotAvailable implements Exception {
  const EpisodeNotAvailable(this.canonical, this.episode, {this.hadTitleMatch = false});
  final ZCanonical canonical;
  final int episode;

  /// True when at least one source matched the show but none could serve this
  /// episode (missing or empty streams).
  final bool hadTitleMatch;

  @override
  String toString() => hadTitleMatch
      ? 'Episode $episode is not available on any source for $canonical'
      : 'No installed source has $canonical';
}

/// Result of a successful play-time resolve for `zm://…/ep/n`.
class ResolvedPlayback {
  const ResolvedPlayback({
    required this.match,
    required this.episodeUrl,
    required this.streams,
    required this.show,
    required this.episode,
  });

  final SourceMatch match;
  final String episodeUrl;
  final List<VideoSource> streams;
  final ZCanonical show;
  final int episode;
}

/// Sweeps installed video sources at play time until one can serve streams for
/// a metadata episode. Winner is cached for [polledSources] and next-episode
/// prefetch on the same session.
class PlaybackResolver {
  PlaybackResolver({
    required SourceMatcher matcher,
    required SourceRepository sources,
    required MatchStore store,
    required ZSourcePrefs prefs,
    required SourceHealthStore health,
    required List<({String id, String name})> Function(ZKind) candidates,
  }) : _matcher = matcher,
       _sources = sources,
       _store = store,
       _prefs = prefs,
       _health = health,
       _candidates = candidates;

  final SourceMatcher _matcher;
  final SourceRepository _sources;
  final MatchStore _store;
  final ZSourcePrefs _prefs;
  final SourceHealthStore _health;
  final List<({String id, String name})> Function(ZKind) _candidates;
  late Future<({String title, String? alt, int? malId})> Function(ZCanonical c)
  _titleLookup;

  /// Wired by [MetadataRepository] after construction to break the cycle.
  void bindTitleLookup(
    Future<({String title, String? alt, int? malId})> Function(ZCanonical c) fn,
  ) {
    _titleLookup = fn;
  }

  /// Cached winning source episode url per `zm://…/ep/n` for poll/prefetch.
  final Map<String, ({String episodeUrl, String sourceId})> _winners = {};

  /// In-flight resolves keyed by metadata episode url.
  final Map<String, Future<ResolvedPlayback>> _inFlight = {};

  /// Resolves [zmEpisodeUrl] to playable streams, trying sources in priority
  /// order until one succeeds.
  Future<ResolvedPlayback> resolveForPlayback(
    String zmEpisodeUrl, {
    bool fast = false,
  }) {
    final running = _inFlight[zmEpisodeUrl];
    if (running != null) return running;
    final f = _resolve(zmEpisodeUrl, fast: fast).whenComplete(() {
      _inFlight.remove(zmEpisodeUrl);
    });
    _inFlight[zmEpisodeUrl] = f;
    return f;
  }

  Future<ResolvedPlayback> _resolve(String zmEpisodeUrl, {required bool fast}) async {
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p == null) {
      throw ArgumentError('not a metadata episode url: $zmEpisodeUrl');
    }
    final t = await _titleLookup(p.show);
    final ordered = _orderedCandidates(p.show);
    if (ordered.isEmpty) throw NoSourceMatch(p.show);

    var hadTitleMatch = false;
    for (final sourceId in ordered) {
      if (CfSolveNeeded.sourceFlagged(sourceId)) continue;
      if (_health.isSkippable(sourceId)) continue;

      final match = await _matcher.matchOn(
        p.show,
        sourceId,
        title: t.title,
        altTitle: t.alt,
        malId: t.malId,
      );
      if (match == null) continue;
      hadTitleMatch = true;

      final srcEp = _episodeAtIndex(
        await _sources.episodes(match.showUrl, sourceId: match.sourceId),
        p.episode,
      );
      if (srcEp == null) continue;

      final streams = await _sources.sources(
        srcEp.url,
        sourceId: match.sourceId,
        fast: fast,
      );
      if (streams.isEmpty) continue;

      _winners[zmEpisodeUrl] = (episodeUrl: srcEp.url, sourceId: match.sourceId);
      if (!match.pinned) {
        await _store.rememberLastPlayed(p.show, match.sourceId);
        await _prefs.set(p.show.kind, match.sourceId);
      }
      debugPrint(
        '[playback] $zmEpisodeUrl -> ${match.sourceId} (${streams.length} streams)',
      );
      return ResolvedPlayback(
        match: match,
        episodeUrl: srcEp.url,
        streams: streams,
        show: p.show,
        episode: p.episode,
      );
    }

    final blocked = _matcher.cfBlockedUrl(p.show.kind);
    if (blocked != null && !hadTitleMatch) {
      // Let CloudflareRequiredException propagate from SourceRepository if thrown;
      // cfBlockedUrl covers suppressed searches.
    }

    if (hadTitleMatch) {
      throw EpisodeNotAvailable(p.show, p.episode, hadTitleMatch: true);
    }
    throw NoSourceMatch(p.show);
  }

  /// Returns streams for [zmEpisodeUrl], sweeping sources when needed.
  Future<List<VideoSource>> sources(String zmEpisodeUrl, {bool fast = false}) async {
    final hit = _winners[zmEpisodeUrl];
    if (hit != null && !fast) {
      return _sources.sources(hit.episodeUrl, sourceId: hit.sourceId, fast: fast);
    }
    return (await resolveForPlayback(zmEpisodeUrl, fast: fast)).streams;
  }

  Future<({List<VideoSource> sources, bool done})> polledSources(
    String zmEpisodeUrl,
  ) async {
    var winner = _winners[zmEpisodeUrl];
    if (winner == null) {
      await resolveForPlayback(zmEpisodeUrl);
      winner = _winners[zmEpisodeUrl];
    }
    if (winner == null) {
      return (sources: const <VideoSource>[], done: true);
    }
    return _sources.polledSources(winner.episodeUrl, sourceId: winner.sourceId);
  }

  /// The source that last resolved [zmEpisodeUrl], if any this session.
  String? resolvedSourceId(String zmEpisodeUrl) =>
      _winners[zmEpisodeUrl]?.sourceId;

  /// n-th entry in [eps] (1-based), same positional rule as detail playback.
  static Episode? _episodeAtIndex(List<Episode> eps, int n) {
    final i = n - 1;
    if (i < 0 || i >= eps.length) return null;
    return eps[i];
  }

  List<String> _orderedCandidates(ZCanonical c) {
    final all = _candidates(c.kind);
    if (all.isEmpty) return const [];

    final ids = all.map((s) => s.id).toList();
    final pinned = _matcher.pinnedSource(c);
    final last = _store.lastPlayed(c);
    final preferred = _prefs.get(c.kind);

    int rank(String id) {
      if (id == pinned) return 0;
      if (id == last) return 1;
      if (id == preferred) return 2;
      return 3 + _healthRank(id);
    }

    final sorted = ids.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
    return sorted;
  }

  int _healthRank(String id) => switch (_health.statusOf(id)) {
    SourceHealth.ok => 0,
    SourceHealth.slow => 1,
    SourceHealth.dead => 2,
  };
}
