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
      debugPrint('[playback] _resolve → ArgumentError: not a zm episode url');
      throw ArgumentError('not a metadata episode url: $zmEpisodeUrl');
    }
    debugPrint(
      '[playback] _resolve · url=$zmEpisodeUrl episode=${p.episode} '
      'show=${p.show.kind}/${p.show.id} fast=$fast',
    );
    final t = await _titleLookup(p.show);
    debugPrint(
      '[playback] _resolve · titleLookup → "${t.title}" '
      '(alt="${t.alt}" malId=${t.malId})',
    );
    final ordered = _orderedCandidates(p.show);
    debugPrint(
      '[playback] _resolve · ${ordered.length} ordered candidates '
      '(${ordered.join(", ")})',
    );
    if (ordered.isEmpty) {
      debugPrint('[playback] _resolve → NoSourceMatch (no candidates)');
      throw NoSourceMatch(p.show);
    }

    var hadTitleMatch = false;
    for (final sourceId in ordered) {
      if (CfSolveNeeded.sourceFlagged(sourceId)) {
        debugPrint(
          '[playback] _resolve · skip $sourceId (CF blocked)',
        );
        continue;
      }
      if (_health.isSkippable(sourceId)) {
        debugPrint(
          '[playback] _resolve · skip $sourceId (unhealthy)',
        );
        continue;
      }

      debugPrint('[playback] _resolve · trying $sourceId');
      final match = await _matcher.matchOn(
        p.show,
        sourceId,
        title: t.title,
        altTitle: t.alt,
        malId: t.malId,
      );
      if (match == null) {
        debugPrint('[playback] _resolve · $sourceId → no title match');
        continue;
      }
      hadTitleMatch = true;

      // Wrap episode + stream resolution in try-catch so a single source
      // throwing (e.g. "no sources in response") doesn't kill the entire
      // sweep — fall through to the next candidate instead.
      try {
        final srcEp = _episodeAtIndex(
          await _sources.episodes(match.showUrl, sourceId: match.sourceId),
          p.episode,
        );
        if (srcEp == null) {
          debugPrint(
            '[playback] _resolve · $sourceId → episode ${p.episode} not found',
          );
          continue;
        }

        final streams = await _sources.sources(
          srcEp.url,
          sourceId: match.sourceId,
          fast: fast,
        );
        if (streams.isEmpty) {
          debugPrint(
            '[playback] _resolve · $sourceId → 0 streams for ep ${p.episode}',
          );
          continue;
        }

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
      } catch (e) {
        debugPrint(
          '[playback] _resolve · $sourceId → error during resolution: $e',
        );
        continue;
      }
    }

    final blocked = _matcher.cfBlockedUrl(p.show.kind);
    if (blocked != null && !hadTitleMatch) {
      debugPrint(
        '[playback] _resolve · CF blocked for kind=${p.show.kind} '
        'url=$blocked',
      );
      // Let CloudflareRequiredException propagate from SourceRepository if thrown;
      // cfBlockedUrl covers suppressed searches.
    }

    if (hadTitleMatch) {
      debugPrint(
        '[playback] _resolve → EpisodeNotAvailable '
        '(hadTitleMatch=true, episode=${p.episode})',
      );
      throw EpisodeNotAvailable(p.show, p.episode, hadTitleMatch: true);
    }
    debugPrint('[playback] _resolve → NoSourceMatch');
    throw NoSourceMatch(p.show);
  }

  /// Returns streams for [zmEpisodeUrl], sweeping sources when needed.
  ///
  /// When a winner is already cached, it is reused regardless of [fast] —
  /// this avoids re-running the full source sweep (title match → episode list
  /// → stream resolve) for the same episode just because the native player's
  /// Server picker calls back for its mirror list. [fast] is still forwarded
  /// to [SourceRepository.sources] so stream URLs are resolved with the fast
  /// path (first usable link) and served from the TTL cache when fresh.
  Future<List<VideoSource>> sources(String zmEpisodeUrl, {bool fast = false}) async {
    final hit = _winners[zmEpisodeUrl];
    if (hit != null) {
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

  /// Drop the cached winner for [zmEpisodeUrl] so the next
  /// [resolveForPlayback] re-sweeps sources instead of reusing the failed one.
  void invalidateWinner(String zmEpisodeUrl) {
    final removed = _winners.remove(zmEpisodeUrl);
    if (removed != null) {
      debugPrint('[playback] invalidateWinner · $zmEpisodeUrl (was ${removed.sourceId})');
    }
  }

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
