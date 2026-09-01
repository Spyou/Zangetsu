import 'package:flutter/foundation.dart';

import '../error/exceptions.dart';
import '../models/media_item.dart';
import '../provider/cf_solve_needed.dart';
import '../repository/source_repository.dart';
import 'match_store.dart';
import 'zmode_ids.dart';
import 'zmode_source_prefs.dart';

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
    required ZSourcePrefs prefs,
    required List<({String id, String name})> Function(ZKind) candidates,
  }) : _sources = sources,
       _store = store,
       _prefs = prefs,
       _candidates = candidates;

  final SourceRepository _sources;
  final MatchStore _store;
  final ZSourcePrefs _prefs;
  final List<({String id, String name})> Function(ZKind) _candidates;

  /// The remembered match for the currently selected source, without
  /// searching. Null when no source is selected, or nothing is stored for it.
  SourceMatch? saved(ZCanonical c) {
    final sel = selectedFor(c.kind);
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
      // Mihon/Aniyomi/LNReader report a challenge by THROWING, and this catch
      // used to drop it on the floor — the source just vanished from matching
      // with nothing recording why, and the solve action had nothing to gate
      // on. Record it exactly as a suppressed JS search does, so the shield
      // can be shown for the sources that actually need it and only those.
      if (e is CloudflareRequiredException) {
        final host = Uri.tryParse(e.url)?.host ?? '';
        if (host.isNotEmpty) {
          CfSolveNeeded.needsSolve(host, e.url, sourceId: sourceId);
        }
      }
      debugPrint('[zmode] $sourceId search THREW for "$title": $e');
      return null;
    }
    // A source that searched fine but title-missed and one that came back
    // empty because it was blocked both just vanish from matching, so say
    // which happened — otherwise "no source has this" is undebuggable.
    debugPrint('[zmode] $sourceId -> ${results.length} results for "$title"');
    final hit = bestTitleMatch(results, title, altTitle: altTitle, wantedMalId: malId);
    if (hit == null || !titleMatches(hit, title, altTitle: altTitle, wantedMalId: malId)) {
      // Remember the no, so the next open of this title skips this source
      // instead of paying for the same search again (see [MatchStore.missTtl])
      // — but "couldn't ask" is not "doesn't have it". A source whose search
      // was suppressed by a Cloudflare challenge comes back EMPTY, and
      // remembering that would hide it for the whole TTL even after a solve.
      if (!CfSolveNeeded.sourceFlagged(sourceId)) {
        await _store.rememberMiss(c, sourceId);
      }
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
    await _store.forgetMiss(c, sourceId);
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
    // Asked recently, said no — don't ask again until the miss expires.
    if (_store.missedRecently(c, sourceId)) return null;
    return resolveOn(c, sourceId, title: title, altTitle: altTitle, malId: malId);
  }

  /// *A* source for this title: honours the stored selection when it's set
  /// and installed — that's a firm choice, so a genuine "this source doesn't
  /// have it" is returned as-is rather than silently trying another source.
  /// Otherwise (no selection yet, or the selected source is gone and
  /// unpinned) sweeps the candidates for [c.kind] in order and selects the
  /// first genuine hit. Null when nothing anywhere genuinely matches — never
  /// throws.
  /// In-flight sweeps, keyed by title. The Detail screen asks twice for the
  /// same title at once — once through `MetadataRepository.detail` for the
  /// episode list, once through the source-selector row — and each sweep is
  /// a real search per installed source. Without this they raced, doubling
  /// the network work and the wait.
  final Map<String, Future<SourceMatch?>> _inFlight = {};


  Future<SourceMatch?> resolve(
    ZCanonical c, {
    required String title,
    String? altTitle,
    int? malId,
  }) {
    final running = _inFlight[c.key];
    if (running != null) return running;
    // Braces, NOT an arrow: Map.remove returns the removed value, and
    // whenComplete awaits a returned Future — an arrow here hands it the very
    // future being completed, so it waits on itself and never finishes.
    final f = _resolve(c, title: title, altTitle: altTitle, malId: malId)
        .whenComplete(() {
      _inFlight.remove(c.key);
    });
    _inFlight[c.key] = f;
    return f;
  }

  Future<SourceMatch?> _resolve(
    ZCanonical c, {
    required String title,
    String? altTitle,
    int? malId,
  }) async {
    final selId = selectedFor(c.kind);
    if (selId == null) return null; // nothing installed that can play this
    return _matchOn(c, selId, title: title, altTitle: altTitle, malId: malId);
  }

  /// The source that plays [kind]: the user's remembered pick when it is still
  /// installed, else the first candidate. Null only when nothing installed can
  /// play this kind at all.
  ///
  /// Synchronous and never searches, which is the point — the Detail screen
  /// reads this to name its source on the first frame. This used to be derived
  /// by searching every installed source in turn and taking whichever had the
  /// title, so the row could name nothing until that finished, and could then
  /// change under the user. One declared source per kind means there is
  /// nothing to wait for and nothing to disagree with; a source that turns out
  /// not to have a title now says so instead of being silently replaced.
  String? selectedFor(ZKind kind) {
    final list = _candidates(kind);
    if (list.isEmpty) return null;
    final saved = _prefs.get(kind);
    if (saved != null && list.any((s) => s.id == saved)) return saved;
    return list.first.id;
  }

  /// Make [sourceId] the source for [kind], for every title of that kind.
  Future<void> selectSource(ZKind kind, String sourceId) =>
      _prefs.set(kind, sourceId);

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
    // The user just proved this source has it, whatever an earlier search
    // concluded — drop any remembered miss so it is never skipped again.
    await _store.forgetMiss(c, picked.sourceId);
    await _prefs.set(c.kind, picked.sourceId);
    return m;
  }
}
