import 'package:flutter/foundation.dart';

import '../error/exceptions.dart';
import '../models/media_item.dart';
import '../provider/cf_solve_needed.dart';
import '../repository/source_repository.dart';
import 'match_store.dart';
import 'playback_resolver.dart' show SweepReason;
import 'zmode_ids.dart';
import 'zmode_source_prefs.dart';

/// Thrown by playback when a metadata title has no source at all.
class NoSourceMatch implements Exception {
  const NoSourceMatch(
    this.canonical, {
    this.outcomes = const [],
    this.selectedSourceName,
  });
  final ZCanonical canonical;

  /// What each candidate did, when this came from a full sweep. Empty when
  /// there was nothing to ask. See `sweepFailureDetail`.
  final List<({String sourceId, String name, SweepReason reason})> outcomes;

  /// Set when a user-selected source alone was checked.
  final String? selectedSourceName;

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
    List<({String id, String name})> Function(ZKind)? sweepCandidates,
  }) : _sources = sources,
       _store = store,
       _prefs = prefs,
       _candidates = candidates,
       _sweepCandidates = sweepCandidates ?? candidates;

  final SourceRepository _sources;
  final MatchStore _store;
  final ZSourcePrefs _prefs;
  final List<({String id, String name})> Function(ZKind) _candidates;

  /// What Auto Resolve actually searches — narrowed to the languages the user
  /// enabled, where [_candidates] is every installed source.
  ///
  /// The two differ because they answer different questions. Reading back a
  /// pin, or checking a kind default, has to see EVERY source: the user chose
  /// that one by hand and hiding it would silently move them somewhere else.
  /// A sweep is the opposite — nobody asked for these, so searching a
  /// language the user turned off is pure cost. It was searching all of them:
  /// 123 sources on a library with the usual multi-language extensions
  /// installed, at up to 3s each.
  final List<({String id, String name})> Function(ZKind) _sweepCandidates;

  /// Called whenever a title's source changes, by any route — a pin, a
  /// correction, the recovery picker, or going back to Auto Resolve.
  ///
  /// Wired to [PlaybackResolver.invalidateShow], which is built later (the
  /// resolver needs this matcher), so it is bound after construction the same
  /// way `bindTitleLookup` is. The resolver caches which source won per
  /// EPISODE and serves playback straight from that cache — without this a
  /// switched title kept playing the old source until the app was restarted.
  /// Notified here rather than at each call site so a new way to change a
  /// source can't forget it.
  void Function(ZCanonical)? _onSourceChanged;

  void bindSourceChanged(void Function(ZCanonical) fn) => _onSourceChanged = fn;

  void _sourceChanged(ZCanonical c) => _onSourceChanged?.call(c);

  /// The remembered match for this title's own source (a pin, else the kind
  /// default), without searching. Null when nothing is known yet — including
  /// when Auto Resolve hasn't swept this title before, even if some installed
  /// source would genuinely match it.
  SourceMatch? saved(ZCanonical c) {
    final sel = sourceForTitle(c);
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
    List<String> metadataAliases = const [],
    int? malId,
    bool Function()? abandoned,
  }) async {
    // On TV, JS providers may not be loaded in the runtime (loadAll was
    // skipped). Ensure the provider is loaded before searching so the JS
    // runtime can actually execute its search function.
    final loaded = await _sources.ensureSourceLoaded(sourceId);
    if (!loaded) {
      debugPrint(
        '[source-matcher] resolveOn · $sourceId → null '
        '(ensureSourceLoaded failed)',
      );
      return null;
    }

    // A provider may index this show by a title other than the catalogue's
    // display title. Measured on a real device: animecube returned no results
    // for "Otome Kaijuu Caraméliser" but listed it as "Kaiju Girl Caramelise".
    // Retry up to three distinct alternate titles only when the first query
    // has no validated match, bounding the extra provider calls on misses.
    Future<List<MediaItem>?> searchFor(String q) async {
      if (abandoned?.call() ?? false) return null;
      try {
        final results = await _sources.search(q, sourceId: sourceId);
        return (abandoned?.call() ?? false) ? null : results;
      } catch (e) {
        // Mihon/Aniyomi/LNReader report a challenge by THROWING, and this
        // catch used to drop it on the floor — the source just vanished from
        // matching with nothing recording why, and the solve action had
        // nothing to gate on. Record it exactly as a suppressed JS search
        // does, so the shield can be shown for the sources that actually need
        // it and only those.
        if (e is CloudflareRequiredException) {
          final host = Uri.tryParse(e.url)?.host ?? '';
          if (host.isNotEmpty) {
            CfSolveNeeded.needsSolve(host, e.url, sourceId: sourceId);
          }
        }
        debugPrint('[zmode] $sourceId search THREW for "$q": $e');
        return null;
      }
    }

    final initialResults = await searchFor(title);
    if (initialResults == null) return null;
    var results = initialResults;
    // A source that searched fine but title-missed and one that came back
    // empty because it was blocked both just vanish from matching, so say
    // which happened — otherwise "no source has this" is undebuggable.
    debugPrint('[zmode] $sourceId -> ${results.length} results for "$title"');
    var hit = bestTitleMatch(
      results,
      title,
      altTitle: altTitle,
      metadataAliases: metadataAliases,
      wantedMalId: malId,
    );
    var matched =
        hit != null &&
        titleMatches(
          hit,
          title,
          altTitle: altTitle,
          metadataAliases: metadataAliases,
          wantedMalId: malId,
        );

    if (!matched) {
      // Search the English name first, then metadata aliases, with a fixed cap
      // on alternate queries to bound provider calls during an Auto Resolve
      // sweep.
      for (final alias in _alternateSearchQueries(
        title,
        altTitle,
        metadataAliases,
      )) {
        if (abandoned?.call() ?? false) return null;
        debugPrint('[zmode] $sourceId · nothing for "$title", trying "$alias"');
        final alternateResults = await searchFor(alias);
        if (alternateResults == null) continue;
        debugPrint(
          '[zmode] $sourceId -> ${alternateResults.length} results for "$alias"',
        );
        final alternateHit = bestTitleMatch(
          alternateResults,
          title,
          altTitle: altTitle,
          metadataAliases: metadataAliases,
          wantedMalId: malId,
        );
        if (alternateHit != null &&
            titleMatches(
              alternateHit,
              title,
              altTitle: altTitle,
              metadataAliases: metadataAliases,
              wantedMalId: malId,
            )) {
          results = alternateResults;
          hit = alternateHit;
          matched = true;
          break;
        }
        hit = alternateHit ?? hit;
      }
    }

    if (!matched) {
      debugPrint(
        '[zmode] $sourceId REJECTED "$title"'
        '${results.isEmpty ? " (no results — blocked or genuinely absent)" : " (best was: ${hit?.title ?? "none"})"}',
      );
      return null;
    }
    // `matched` is only true when `hit` is non-null, but `hit` is reassignable
    // now (the second search can replace it), so it does not promote — pin it
    // to a final here rather than sprinkling `!` through the constructor.
    final found = hit!;
    debugPrint('[zmode] $sourceId MATCHED "$title" -> "${found.title}"');
    final m = SourceMatch(
      sourceId: found.sourceId,
      showUrl: found.url,
      showId: found.id,
      showTitle: found.title,
      pinned: false,
    );
    if (abandoned?.call() ?? false) return null;
    await _store.save(c, m);
    return m;
  }

  static List<String> _alternateSearchQueries(
    String title,
    String? altTitle,
    List<String> metadataAliases,
  ) {
    final seen = {normalizeTitle(title)};
    final queries = <String>[];
    for (final candidate in [?altTitle, ...metadataAliases]) {
      final query = candidate.trim();
      final key = normalizeTitle(query);
      if (query.isEmpty || key.isEmpty || !seen.add(key)) continue;
      queries.add(query);
      if (queries.length == 3) break;
    }
    return queries;
  }

  /// A source's remembered/fresh match — a pinned match always wins (even if
  /// the source was since uninstalled); an unpinned match is trusted only
  /// while the source is still installed (otherwise it's stale — null so the
  /// caller re-searches); anything else searches fresh via [resolveOn].
  /// A source's remembered/fresh match — see [_matchOn].
  Future<SourceMatch?> matchOn(
    ZCanonical c,
    String sourceId, {
    required String title,
    String? altTitle,
    List<String> metadataAliases = const [],
    int? malId,
    bool Function()? abandoned,
  }) async {
    if (abandoned?.call() ?? false) return null;
    final saved = _store.get(c, sourceId);
    // An empty showUrl is a pin with no match behind it — the user picked a
    // source that didn't have the title. It is a real choice, so it keeps
    // outranking every other source, but it is not a result: fall through and
    // ask again rather than handing back a match with nowhere to point.
    final savedIsMatch = saved != null && saved.showUrl.isNotEmpty;
    if (savedIsMatch && (saved.pinned || _sources.hasSource(sourceId))) {
      // Even with a cached match, the runtime may be empty on TV — ensure
      // the provider is loaded so episodes()/sources() can resolve.
      final loaded = await _sources.ensureSourceLoaded(sourceId);
      if (abandoned?.call() ?? false) return null;
      debugPrint(
        '[source-matcher] matchOn · "$sourceId" → cached '
        '(pinned=${saved.pinned} installed=${_sources.hasSource(sourceId)} '
        'loaded=$loaded)',
      );
      return loaded ? saved : null;
    }
    if (!_sources.hasSource(sourceId)) {
      debugPrint(
        '[source-matcher] matchOn · "$sourceId" → null '
        '(not installed)',
      );
      return null;
    }
    // No negative cache: a previous miss must not skip this source on the
    // next episode tap. Successful matches above still short-circuit.
    debugPrint(
      '[source-matcher] matchOn · "$sourceId" → fresh search '
      'for "$title"',
    );
    return resolveOn(
      c,
      sourceId,
      title: title,
      altTitle: altTitle,
      metadataAliases: metadataAliases,
      malId: malId,
      abandoned: abandoned,
    );
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
  final Map<String, void Function()> _cancelInFlight = {};
  final Map<String, ({String sourceName, int current, int total})>
  _resolveProgress = {};
  final Map<
    String,
    Set<void Function(String sourceName, int current, int total)>
  >
  _resolveProgressListeners = {};

  void _publishProgress(String key, String sourceName, int current, int total) {
    final progress = (sourceName: sourceName, current: current, total: total);
    _resolveProgress[key] = progress;
    for (final listener
        in _resolveProgressListeners[key]?.toList() ?? const []) {
      listener(sourceName, current, total);
    }
  }

  /// Stop the current Auto Resolve title sweep after its active provider call
  /// returns. The provider API has no cancellation handle for that call.
  void cancelResolve(ZCanonical c) => _cancelInFlight[c.key]?.call();

  Future<SourceMatch?> resolve(
    ZCanonical c, {
    required String title,
    String? altTitle,
    List<String> metadataAliases = const [],
    int? malId,
    bool Function()? abandoned,
    void Function(String sourceName, int current, int total)? onProgress,
  }) {
    if (onProgress != null) {
      _resolveProgressListeners.putIfAbsent(c.key, () => {}).add(onProgress);
      final progress = _resolveProgress[c.key];
      if (progress != null) {
        onProgress(progress.sourceName, progress.current, progress.total);
      }
    }
    final running = _inFlight[c.key];
    if (running != null) return running;
    var cancelled = false;
    void cancel() => cancelled = true;
    _cancelInFlight[c.key] = cancel;
    bool gone() => cancelled || (abandoned?.call() ?? false);
    // Braces, NOT an arrow: Map.remove returns the removed value, and
    // whenComplete awaits a returned Future — an arrow here hands it the very
    // future being completed, so it waits on itself and never finishes.
    final f =
        _resolve(
          c,
          title: title,
          altTitle: altTitle,
          metadataAliases: metadataAliases,
          malId: malId,
          abandoned: gone,
          onProgress: (sourceName, current, total) =>
              _publishProgress(c.key, sourceName, current, total),
        ).whenComplete(() {
          _inFlight.remove(c.key);
          _resolveProgress.remove(c.key);
          _resolveProgressListeners.remove(c.key);
          if (identical(_cancelInFlight[c.key], cancel)) {
            _cancelInFlight.remove(c.key);
          }
        });
    _inFlight[c.key] = f;
    return f;
  }

  Future<SourceMatch?> _resolve(
    ZCanonical c, {
    required String title,
    String? altTitle,
    List<String> metadataAliases = const [],
    int? malId,
    bool Function()? abandoned,
    void Function(String sourceName, int current, int total)? onProgress,
  }) async {
    if (abandoned?.call() ?? false) {
      debugPrint(
        '[source-matcher] _resolve · abandoned before source selection',
      );
      return null;
    }
    final candidates = _candidates(c.kind);
    // A per-title pin ("Wrong title?" or the picker) is a firm choice — it
    // wins over everything else, including an explicit kind default.
    final pinned = pinnedSource(c);
    if (pinned != null) {
      debugPrint(
        '[source-matcher] _resolve · kind=${c.kind} title="$title" '
        'pinned=$pinned',
      );
      return matchOn(
        c,
        pinned,
        title: title,
        altTitle: altTitle,
        metadataAliases: metadataAliases,
        malId: malId,
        abandoned: abandoned,
      );
    }
    // An explicit kind-wide default (set via the "source went quiet" recovery
    // picker) is honoured as-is — a genuine miss there is reported, not
    // silently papered over by trying another source.
    final selId = _prefs.get(c.kind);
    if (selId != null && candidates.any((s) => s.id == selId)) {
      debugPrint(
        '[source-matcher] _resolve · kind=${c.kind} title="$title" '
        'kind default=$selId',
      );
      return matchOn(
        c,
        selId,
        title: title,
        altTitle: altTitle,
        metadataAliases: metadataAliases,
        malId: malId,
        abandoned: abandoned,
      );
    }
    final sweep = _sweepCandidates(c.kind);

    // Reading uses its remembered source, and does not sweep.
    //
    // A sweep is only safe where something can recover from a bad pick. Video
    // has that — PlaybackResolver re-resolves per episode at tap time, so an
    // unlucky source costs nothing. Reading has no second chance: the matched
    // source OWNS the chapter list, so landing on one carrying 3 of 200
    // chapters is worse than not sweeping, and the reader cannot tell why.
    //
    // A miss here is reported as a miss — the screen says "no episodes
    // available from this source" and offers the picker, which is what a
    // reader expects and can act on. Silently reaching for a different source
    // is how you end up reading someone else's numbering.
    //
    // The sweep below is a one-time bootstrap for reading: it runs when
    // nothing is remembered yet, and whatever matches is kept. "Auto Resolve"
    // in the per-title picker clears that memory (see [clearAuto]), so
    // sweeping stays reachable on purpose.
    final isReading = c.kind == ZKind.manga || c.kind == ZKind.novel;
    final remembered = isReading ? _prefs.lastGood(c.kind) : null;
    if (remembered != null && sweep.any((s) => s.id == remembered)) {
      debugPrint(
        '[source-matcher] _resolve · kind=${c.kind} title="$title" '
        'reading source=$remembered',
      );
      return matchOn(
        c,
        remembered,
        title: title,
        altTitle: altTitle,
        metadataAliases: metadataAliases,
        malId: malId,
      );
    }

    // Auto Resolve — the true default until the user pins a title or sets a
    // kind default by hand: sweep every candidate, in the user's saved
    // priority order, and take the first genuine hit.
    debugPrint(
      '[source-matcher] _resolve · kind=${c.kind} title="$title" '
      'AUTO — sweeping ${sweep.length} candidates '
      '(${sweep.map((s) => s.id).take(5).join(",")}'
      '${sweep.length > 5 ? "…" : ""})',
    );
    for (var i = 0; i < sweep.length; i++) {
      final s = sweep[i];
      // The viewer left: stop before the next source. Going back out of a detail
      // screen used to leave this sweep running, so tapping titles quickly piled
      // up one live search per screen and each new tap waited behind all the
      // abandoned ones. Checking between sources — not just before the sweep —
      // is what stops a pile mid-build, since the sweep may run through many
      // sources and only the between-sources check can end it without waiting
      // for the current one to finish.
      final left = abandoned?.call() ?? false;
      if (left) {
        debugPrint(
          '[source-matcher] _resolve · abandoned before "${s.id}", viewer left',
        );
        return null;
      }
      onProgress?.call(s.name, i + 1, sweep.length);
      final m = await matchOn(
        c,
        s.id,
        title: title,
        altTitle: altTitle,
        metadataAliases: metadataAliases,
        malId: malId,
        abandoned: abandoned,
      );
      if (abandoned?.call() ?? false) return null;
      if (m != null) {
        debugPrint('[source-matcher] _resolve · AUTO → ${s.id}');
        if (isReading) await _prefs.rememberLastGood(c.kind, s.id);
        return m;
      }
    }
    debugPrint(
      '[source-matcher] _resolve · AUTO → null (no candidate matched)',
    );
    return null;
  }

  /// Which [sourceId] has a pinned match for [c], if any.
  String? pinnedSource(ZCanonical c) {
    for (final s in _candidates(c.kind)) {
      if (_store.get(c, s.id)?.pinned == true) return s.id;
    }
    return null;
  }

  /// The explicit kind default, when one has been set and is still installed
  /// — null otherwise (including when nothing has ever been chosen, which is
  /// what makes Auto Resolve the true default). Synchronous and never
  /// searches, so the Detail screen can name a fixed source on the first
  /// frame; it says nothing about what Auto Resolve itself will land on.
  String? selectedFor(ZKind kind) {
    final list = _candidates(kind);
    final saved = _prefs.get(kind);
    if (saved != null && list.any((s) => s.id == saved)) {
      debugPrint(
        '[source-matcher] selectedFor($kind) → "$saved" (saved, still valid)',
      );
      return saved;
    }
    debugPrint('[source-matcher] selectedFor($kind) → null (no kind default)');
    return null;
  }

  /// This title's own source: a per-title pin first, else the explicit kind
  /// default, else — for reading — the source reading settled on, else null,
  /// meaning Auto Resolve is in effect for it.
  ///
  /// The order mirrors [_resolve] exactly, and has to: this is what the Detail
  /// screen NAMES on the row, what the Cloudflare shield acts on, and what
  /// "Wrong title?" compares against. Reading stopped sweeping, so leaving it
  /// out here labelled every manga "Auto Resolve" while a fixed source was
  /// quietly serving it — the row saying one thing and the chapters coming
  /// from another is the exact confusion this whole area keeps producing.
  String? sourceForTitle(ZCanonical c) {
    final chosen = pinnedSource(c) ?? selectedFor(c.kind);
    if (chosen != null) return chosen;
    if (c.kind != ZKind.manga && c.kind != ZKind.novel) return null;
    final remembered = _prefs.lastGood(c.kind);
    // Uninstalled or switched off since: fall back to Auto Resolve rather than
    // naming a source that cannot answer.
    if (remembered == null) return null;
    return _sweepCandidates(c.kind).any((s) => s.id == remembered)
        ? remembered
        : null;
  }

  /// Make [sourceId] the explicit default for [kind], for every title of that
  /// kind that isn't itself pinned to something else.
  Future<void> selectSource(ZKind kind, String sourceId) =>
      _prefs.set(kind, sourceId);

  /// The "source went quiet" recovery picker: clears this title's own pin (a
  /// stale pin would otherwise keep pointing at the dead source) and sets
  /// [sourceId] as the kind's new explicit default.
  Future<void> chooseSource(ZCanonical c, String sourceId) async {
    await clearTitlePin(c);
    await selectSource(c.kind, sourceId);
  }

  /// The user picked [sourceId] for THIS title only, from the source picker —
  /// searches it fresh (or reuses a cached match) and pins whatever it finds,
  /// without touching any other title of this kind or the kind default. Null
  /// when [sourceId] genuinely doesn't have this title — nothing is pinned,
  /// so the next resolve falls back to the kind default / Auto Resolve.
  Future<SourceMatch?> pinTitleToSource(
    ZCanonical c,
    String sourceId, {
    required String title,
    String? altTitle,
    List<String> metadataAliases = const [],
    int? malId,
  }) async {
    final m = await matchOn(
      c,
      sourceId,
      title: title,
      altTitle: altTitle,
      metadataAliases: metadataAliases,
      malId: malId,
    );
    if (m == null) {
      // The source has nothing for this title — but the user still CHOSE it,
      // and that has to stick. Returning here without writing anything left
      // the previous source pinned, so the picker named the new source while
      // the old one went on serving the chapter list, the reader and the
      // downloads. Pin it with no match instead: the screen already says "no
      // episodes available from this source", which is the truth.
      await _store.pin(
        c,
        SourceMatch(
          sourceId: sourceId,
          showUrl: '',
          showId: '',
          showTitle: '',
          pinned: true,
        ),
      );
      _sourceChanged(c);
      return null;
    }
    final pin = SourceMatch(
      sourceId: m.sourceId,
      showUrl: m.showUrl,
      showId: m.showId,
      showTitle: m.showTitle,
      pinned: true,
    );
    await _store.pin(c, pin);
    _sourceChanged(c);
    return pin;
  }

  /// Drop this title's own pin — it goes back to the kind default / Auto
  /// Resolve, exactly like a title that was never pinned.
  Future<void> clearTitlePin(ZCanonical c) async {
    await _store.unpinAll(c);
    // Covers chooseSource and clearAuto too: both come through here.
    _sourceChanged(c);
  }

  /// The picker's "Auto Resolve": drops this title's own pin AND the kind's
  /// explicit default, so this title (and every other unpinned title of the
  /// kind) genuinely sweeps again. A per-title pin alone isn't enough here —
  /// a kind default set earlier (e.g. via [chooseSource]) would otherwise
  /// keep outranking Auto Resolve and the picker would never actually show it.
  Future<void> clearAuto(ZCanonical c) async {
    await clearTitlePin(c);
    await _prefs.clear(c.kind);
    // Reading remembers the source that last matched and starts there instead
    // of sweeping. Picking "Auto Resolve" has to forget that too, or the very
    // next resolve snaps straight back to it and the choice does nothing.
    await _prefs.clearLastGood(c.kind);
    await _store.clearLastPlayed(c);
  }

  /// The Cloudflare-challenge url for a [kind] candidate that got flagged
  /// mid-search (see [CfSolveNeeded]), or null. [resolve] returning null
  /// doesn't say WHY — this lets a caller tell "genuinely not on any
  /// source" apart from "was on a source, but the search got suppressed by
  /// a Cloudflare challenge" and offer a solve instead of a flat miss.
  String? cfBlockedUrl(ZKind kind) =>
      CfSolveNeeded.urlForAny(_candidates(kind).map((s) => s.id));

  /// The user picked [picked] by hand from "Wrong title?". Pinned for its
  /// source, this title only — like [pinForTitle], the kind default is left
  /// alone.
  ///
  /// It used to set that default too, so correcting one show's match silently
  /// re-pointed every other anime and movie at that source and, because a kind
  /// default is honoured as-is, switched Auto Resolve off for all of them.
  /// Saying "this show is really X on this source" is a statement about one
  /// title, not about the library.
  Future<SourceMatch> pinManual(ZCanonical c, MediaItem picked) async {
    final m = SourceMatch(
      sourceId: picked.sourceId,
      showUrl: picked.url,
      showId: picked.id,
      showTitle: picked.title,
      pinned: true,
    );
    await _store.pin(c, m);
    _sourceChanged(c);
    return m;
  }

  /// Browsing a source directly and opening a show there: a choice about
  /// THIS show, so unlike [pinManual] the kind default is left alone — one
  /// tap here must never silently re-point every other title of the kind.
  Future<SourceMatch> pinForTitle(ZCanonical c, MediaItem picked) async {
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
