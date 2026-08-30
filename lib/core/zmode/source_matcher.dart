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

  /// The remembered match, or a fresh guess searched source-by-source, in
  /// order, stopping at the first genuine hit. Null when nothing genuinely
  /// matches anywhere — never throws.
  ///
  /// [bestTitleMatch] falls back to a source's top result when nothing in it
  /// matches exactly, so its verdict is only used to rank a source's own
  /// results — the hit is then checked against [titleMatches] before it's
  /// trusted, otherwise an unrelated top result from an early source would
  /// get accepted as this title and "no source has this yet" would become
  /// unreachable.
  Future<SourceMatch?> resolve(
    ZCanonical c, {
    required String title,
    String? altTitle,
    int? malId,
  }) async {
    final saved = _store.get(c);
    if (saved != null) return saved;

    for (final s in _candidates(c.kind)) {
      List<MediaItem> results;
      try {
        results = await _sources.search(title, sourceId: s.id);
      } catch (e) {
        debugPrint('[zmode] ${s.id} search failed for "$title": $e');
        continue;
      }
      final hit = bestTitleMatch(results, title, altTitle: altTitle, wantedMalId: malId);
      if (hit == null || !titleMatches(hit, title, altTitle: altTitle, wantedMalId: malId)) {
        continue;
      }
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
    return null;
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
