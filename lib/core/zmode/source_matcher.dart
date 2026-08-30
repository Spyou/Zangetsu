import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../repository/source_repository.dart';
import 'match_store.dart';
import 'zmode_ids.dart';

/// Thrown by playback when a metadata title has no source at all.
class NoSourceMatch implements Exception {
  const NoSourceMatch(this.canonical);
  final ZCanonical canonical;
  @override
  String toString() => 'No installed source has $canonical';
}

/// Finds the source show behind a metadata title. It is a guess by title, so
/// the result is remembered and can be corrected ("Wrong show?"), and a
/// correction is never re-guessed.
class SourceMatcher {
  SourceMatcher({
    required SourceRepository sources,
    required MatchStore store,
    required List<({String id, String name})> Function(ZKind) candidates,
  }) : _sources = sources,
       _store = store,
       _candidates = candidates;

  final SourceRepository _sources;
  final MatchStore _store;
  final List<({String id, String name})> Function(ZKind) _candidates;

  /// The remembered match, or a fresh guess searched across every installed
  /// source of this kind. Null when nothing has it — never throws.
  ///
  /// Every source's results are pooled before ranking, not accepted
  /// source-by-source: [bestTitleMatch] falls back to its first argument's
  /// first item when nothing matches exactly, so ranking one source's
  /// results at a time would let an irrelevant hit from an earlier source
  /// win over a real match sitting in a later one.
  Future<SourceMatch?> resolve(
    ZCanonical c, {
    required String title,
    String? altTitle,
    int? malId,
  }) async {
    final saved = _store.get(c);
    if (saved != null) return saved;

    final pool = <MediaItem>[];
    for (final s in _candidates(c.kind)) {
      try {
        pool.addAll(await _sources.search(title, sourceId: s.id));
      } catch (e) {
        debugPrint('[zmode] ${s.id} search failed for "$title": $e');
      }
    }

    final hit = bestTitleMatch(pool, title, altTitle: altTitle, wantedMalId: malId);
    if (hit == null) return null;
    final m = SourceMatch(
      sourceId: hit.sourceId,
      showUrl: hit.url,
      showId: hit.id,
      showTitle: hit.title,
      pinned: false,
    );
    await _store.save(c, m);
    return m;
  }

  /// The user picked [picked] by hand. Pinned, so it sticks.
  Future<SourceMatch> pinManual(ZCanonical c, MediaItem picked) async {
    final m = SourceMatch(
      sourceId: picked.sourceId,
      showUrl: picked.url,
      showId: picked.id,
      showTitle: picked.title,
      pinned: true,
    );
    await _store.pin(c, m);
    return m;
  }
}
