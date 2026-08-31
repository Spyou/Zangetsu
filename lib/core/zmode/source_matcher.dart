import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../provider/cf_solve_needed.dart';
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

/// Thrown when a title's matched source has no episode with this number —
/// the show was found, this episode was not.
class EpisodeNotOnSource implements Exception {
  const EpisodeNotOnSource(this.canonical, this.episode);
  final ZCanonical canonical;
  final int episode;
  @override
  String toString() => 'Episode $episode is not on the source for $canonical';
}

/// Finds the source show behind a metadata title, one source at a time. Each
/// source keeps its own remembered match, so the result is a guess that can
/// be corrected ("Wrong title?") per source, and a correction is never
/// re-guessed. One source is always the current "selected" one — the one
/// episodes/playback use — and [resolve] is what keeps that selection.
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

  /// The remembered match for the currently selected source, without
  /// searching. Null when no source is selected, or nothing is stored for it.
  SourceMatch? saved(ZCanonical c) {
    final sel = _store.selectedSource(c);
    return sel == null ? null : _store.get(c, sel);
  }

  /// Match this title on exactly [sourceId]. Null when that source genuinely
  /// doesn't have it — never throws. A genuine hit is saved as a guess (a
  /// no-op if [sourceId] is already pinned for this title).
  ///
  /// [bestTitleMatch] falls back to the source's top result when nothing in
  /// it matches exactly, so its verdict is only used to rank this source's
  /// own results — the hit is then checked against [titleMatches] before
  /// it's trusted, otherwise an unrelated top result would get accepted as
  /// this title and "no source has this yet" would become unreachable.
  Future<SourceMatch?> resolveOn(
    ZCanonical c,
    String sourceId, {
    required String title,
    String? altTitle,
    int? malId,
  }) async {
    List<MediaItem> results;
    try {
      results = await _sources.search(title, sourceId: sourceId);
    } catch (e) {
      debugPrint('[zmode] $sourceId search THREW for "$title": $e');
      return null;
    }
    // Diagnostic: every candidate and its outcome. Without this a source that
    // searched fine but title-missed, and one that came back empty because it
    // was blocked, are indistinguishable — both just vanish from matching.
    debugPrint('[zmode] $sourceId -> ${results.length} results for "$title"');
    final hit = bestTitleMatch(results, title, altTitle: altTitle, wantedMalId: malId);
    if (hit == null || !titleMatches(hit, title, altTitle: altTitle, wantedMalId: malId)) {
      debugPrint(
        '[zmode] $sourceId REJECTED "$title"'
        '${results.isEmpty ? " (no results — blocked or genuinely absent)" : " (best was: ${hit?.title ?? "none"})"}',
      );
      return null;
    }
    debugPrint('[zmode] $sourceId MATCHED "$title" -> "${hit.title}"');
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

  /// A source's remembered/fresh match — a pinned match always wins (even if
  /// the source was since uninstalled); an unpinned match is trusted only
  /// while the source is still installed (otherwise it's stale — null so the
  /// caller re-searches); anything else searches fresh via [resolveOn].
  Future<SourceMatch?> _matchOn(
    ZCanonical c,
    String sourceId, {
    required String title,
    String? altTitle,
    int? malId,
  }) async {
    final saved = _store.get(c, sourceId);
    if (saved != null && (saved.pinned || _sources.hasSource(sourceId))) {
      return saved;
    }
    if (!_sources.hasSource(sourceId)) return null;
    return resolveOn(c, sourceId, title: title, altTitle: altTitle, malId: malId);
  }

  /// *A* source for this title: honours the stored selection when it's set
  /// and installed — that's a firm choice, so a genuine "this source doesn't
  /// have it" is returned as-is rather than silently trying another source.
  /// Otherwise (no selection yet, or the selected source is gone and
  /// unpinned) sweeps the candidates for [c.kind] in order and selects the
  /// first genuine hit. Null when nothing anywhere genuinely matches — never
  /// throws.
  Future<SourceMatch?> resolve(
    ZCanonical c, {
    required String title,
    String? altTitle,
    int? malId,
  }) async {
    final selId = _store.selectedSource(c);
    if (selId != null) {
      final r = await _matchOn(c, selId, title: title, altTitle: altTitle, malId: malId);
      if (r != null) return r;
      if (_sources.hasSource(selId)) return null;
      // Selected source is gone and had nothing pinned — fall through and
      // pick a new one below.
    }

    for (final s in _candidates(c.kind)) {
      if (s.id == selId) continue; // already checked above
      final hit = await _matchOn(c, s.id, title: title, altTitle: altTitle, malId: malId);
      if (hit != null) {
        await _store.selectSource(c, s.id);
        return hit;
      }
    }
    return null;
  }

  /// The Cloudflare-challenge url for a [kind] candidate that got flagged
  /// mid-search (see [CfSolveNeeded]), or null. [resolve] returning null
  /// doesn't say WHY — this lets a caller tell "genuinely not on any
  /// source" apart from "was on a source, but the search got suppressed by
  /// a Cloudflare challenge" and offer a solve instead of a flat miss.
  String? cfBlockedUrl(ZKind kind) =>
      CfSolveNeeded.urlForAny(_candidates(kind).map((s) => s.id));

  /// The user picked [picked] by hand. Pinned for its source, and that
  /// source becomes the selected one for this title.
  Future<SourceMatch> pinManual(ZCanonical c, MediaItem picked) async {
    final m = SourceMatch(
      sourceId: picked.sourceId,
      showUrl: picked.url,
      showId: picked.id,
      showTitle: picked.title,
      pinned: true,
    );
    await _store.pin(c, m);
    await _store.selectSource(c, picked.sourceId);
    return m;
  }
}
