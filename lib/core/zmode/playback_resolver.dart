import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/video_source.dart';
import '../playback/source_health_store.dart';
import '../di/injector.dart';
import '../provider/cf_solve_needed.dart';
import '../provider/provider_manager.dart';
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

    /// Overridable so tests don't have to wait [defaultPerSourceBudget] out.
    Duration? perSourceBudget,
  }) : _budget = perSourceBudget ?? defaultPerSourceBudget,
       _matcher = matcher,
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
  ///
  /// Keyed by url AND category: sub and dub are different episode lists for
  /// the same metadata url, so a single key would hand a dub request whatever
  /// sub resolved earlier — the same stale-cache shape that made a switched
  /// source keep playing the old one.
  final Map<String, ({String episodeUrl, String sourceId})> _winners = {};

  static String _winKey(String zmEpisodeUrl, String category) =>
      '$zmEpisodeUrl|$category';

  /// In-flight resolves keyed by metadata episode url.
  final Map<String, Future<ResolvedPlayback>> _inFlight = {};

  /// How long one candidate may hold the sweep before we move on. Measured on
  /// a real device: a JS provider with its own 15s internal timeout took 15.8s
  /// and then 38s, an Aniyomi source sat 12.5s on a Cloudflare page, another
  /// 7.3s before an IOException — four sources turned a single Play tap into
  /// 100 seconds of frozen UI, because JS providers run on this isolate and a
  /// second spent in one is a second of frames not drawn.
  static const Duration defaultPerSourceBudget = Duration(seconds: 8);
  final Duration _budget;

  /// Tighter than [_budget], because the two are asking different questions.
  /// Playback is worth waiting 8s for — it is the thing you asked for. A
  /// browse list is not: a source that cannot say whether it lists an episode
  /// within 5 seconds is not the one you are about to pick.
  static const Duration probeBudget = Duration(seconds: 5);

  /// Sources that blew [perSourceBudget], and when. Without this the very next
  /// sweep pays the same 38 seconds again — which is exactly what the device
  /// log showed, twice in a row for the same source.
  ///
  /// Deliberately NOT [SourceHealthStore]: a timeout there is recorded as
  /// "alive but slow" on purpose, so a slow source keeps appearing in search
  /// results (see its `record`). This is a playback-only, session-only memory
  /// with its own short cooldown, so nothing about search changes.
  final Map<String, DateTime> _overBudget = {};
  static const Duration overBudgetCooldown = Duration(minutes: 10);

  /// Sweeps that ended with nothing able to serve the episode, and when.
  ///
  /// The catalogue routinely lists more episodes than any source has — an
  /// airing show's announced count, a season pack a source hasn't finished —
  /// so the LAST episode of a title is often one nobody can play. Rediscovering
  /// that cost a real episode-list fetch against EVERY candidate, ~25s of
  /// frozen UI, and it ran again the moment Home re-asked after you backed out
  /// of the player. The answer doesn't change minute to minute; remember it.
  ///
  /// Short-lived and cleared by [invalidateWinner], so installing a source,
  /// solving a Cloudflare challenge or hitting Retry all get a fresh sweep.
  final Map<String, ({DateTime at, bool hadTitleMatch})> _noSource = {};
  static const Duration noSourceCooldown = Duration(minutes: 5);

  bool _recentlyOverBudget(String id) {
    final at = _overBudget[id];
    if (at == null) return false;
    if (DateTime.now().difference(at) < overBudgetCooldown) return true;
    _overBudget.remove(id);
    return false;
  }

  /// Resolves [zmEpisodeUrl] to playable streams, trying sources in priority
  /// order until one succeeds.
  Future<ResolvedPlayback> resolveForPlayback(
    String zmEpisodeUrl, {
    bool fast = false,
    String category = 'sub',
    bool Function(List<VideoSource> streams)? accept,
  }) {
    // A filtered sweep asks a narrower question; it must neither be answered
    // by, nor become, the shared in-flight future.
    // In-flight dedupe is per category too — a dub request must not be
    // answered by a sub resolve already running for the same url.
    final flightKey = _winKey(zmEpisodeUrl, category);
    if (accept == null) {
      final running = _inFlight[flightKey];
      if (running != null) return running;
    }
    final miss = _noSource[flightKey];
    if (miss != null) {
      if (DateTime.now().difference(miss.at) < noSourceCooldown) {
        debugPrint(
          '[playback] resolveForPlayback · $zmEpisodeUrl → no source '
          '(remembered, skipping the sweep)',
        );
        final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
        return Future.error(
          p == null || !miss.hadTitleMatch
              ? NoSourceMatch(p?.show ?? const ZCanonical(ZKind.anime, ''))
              : EpisodeNotAvailable(p.show, p.episode, hadTitleMatch: true),
        );
      }
      _noSource.remove(flightKey);
    }
    if (accept != null) {
      return _resolve(zmEpisodeUrl, fast: fast, category: category, accept: accept);
    }
    final f = _resolve(zmEpisodeUrl, fast: fast, category: category)
        .whenComplete(() {
      _inFlight.remove(flightKey);
    });
    _inFlight[flightKey] = f;
    return f;
  }

  Future<ResolvedPlayback> _resolve(
    String zmEpisodeUrl, {
    required bool fast,
    String category = 'sub',
    bool Function(List<VideoSource> streams)? accept,
  }) async {
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
      if (_recentlyOverBudget(sourceId)) {
        debugPrint(
          '[playback] _resolve · skip $sourceId (over budget recently)',
        );
        continue;
      }

      debugPrint('[playback] _resolve · trying $sourceId');
      // The try/catch is per candidate, not around the sweep: one source
      // throwing ("no sources in response") or hanging must not kill the
      // others — fall through to the next candidate instead.
      _Attempt? attempt;
      try {
        attempt = await _tryCandidate(
          p,
          sourceId,
          t,
          fast: fast,
          category: category,
          onTitleMatch: () => hadTitleMatch = true,
        ).timeout(_budget);
      } on TimeoutException {
        _overBudget[sourceId] = DateTime.now();
        debugPrint(
          '[playback] _resolve · $sourceId → over ${_budget.inSeconds}s '
          'budget, skipping it for ${overBudgetCooldown.inMinutes}m',
        );
      } catch (e) {
        debugPrint(
          '[playback] _resolve · $sourceId → error during resolution: $e',
        );
      }
      if (attempt == null) continue;

      // The caller can require more than "has streams". Downloading does: a
      // source can play perfectly and still hand back only DASH manifests,
      // which never become a file. Asking here keeps it to ONE sweep that
      // walks every candidate — the alternative was re-running the whole
      // sweep per rejected source, which is quadratic and froze the app.
      if (accept != null && !accept(attempt.streams)) {
        debugPrint(
          '[playback] _resolve · ${attempt.match.sourceId} answered but the '
          'caller rejected its streams — next candidate',
        );
        continue;
      }

      // A filtered sweep answers a narrower question, so it must not become
      // the remembered winner: playback would inherit a source picked for
      // being downloadable rather than for playing well.
      if (accept != null) {
        return ResolvedPlayback(
          match: attempt.match,
          episodeUrl: attempt.episodeUrl,
          streams: attempt.streams,
          show: p.show,
          episode: p.episode,
        );
      }

      // Written here rather than inside _tryCandidate so an abandoned
      // (timed-out) candidate that finishes later can never overwrite the
      // winner of the source we actually settled on.
      _winners[_winKey(zmEpisodeUrl, category)] =
          (episodeUrl: attempt.episodeUrl, sourceId: attempt.match.sourceId);
      // Per-title only — remembered for THIS show's own re-ranking (see
      // `_orderedCandidates`). This must never write the kind-wide
      // `ZSourcePrefs` default: that's an explicit, rare user choice (the
      // "source went quiet" recovery picker), and a single successful
      // Auto Resolve play silently promoting itself to play EVERY title of
      // the kind is exactly the bug this design fixes.
      if (!attempt.match.pinned) {
        await _store.rememberLastPlayed(p.show, attempt.match.sourceId);
      }
      debugPrint(
        '[playback] $zmEpisodeUrl -> ${attempt.match.sourceId} '
        '(${attempt.streams.length} streams)',
      );
      return ResolvedPlayback(
        match: attempt.match,
        episodeUrl: attempt.episodeUrl,
        streams: attempt.streams,
        show: p.show,
        episode: p.episode,
      );
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

    _noSource[_winKey(zmEpisodeUrl, category)] =
        (at: DateTime.now(), hadTitleMatch: hadTitleMatch);
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
  Future<List<VideoSource>> sources(
    String zmEpisodeUrl, {
    bool fast = false,
    String category = 'sub',
  }) async {
    final hit = _winners[_winKey(zmEpisodeUrl, category)];
    if (hit != null) {
      return _sources.sources(hit.episodeUrl, sourceId: hit.sourceId, fast: fast);
    }
    return (await resolveForPlayback(
      zmEpisodeUrl,
      fast: fast,
      category: category,
    )).streams;
  }

  Future<({List<VideoSource> sources, bool done})> polledSources(
    String zmEpisodeUrl, {
    String category = 'sub',
  }) async {
    final key = _winKey(zmEpisodeUrl, category);
    var winner = _winners[key];
    if (winner == null) {
      await resolveForPlayback(zmEpisodeUrl, category: category);
      winner = _winners[key];
    }
    if (winner == null) {
      return (sources: const <VideoSource>[], done: true);
    }
    return _sources.polledSources(winner.episodeUrl, sourceId: winner.sourceId);
  }

  /// The source that last resolved [zmEpisodeUrl], if any this session.
  String? resolvedSourceId(String zmEpisodeUrl, {String category = 'sub'}) =>
      _winners[_winKey(zmEpisodeUrl, category)]?.sourceId;

  /// Drop the cached winner for [zmEpisodeUrl] so the next
  /// [resolveForPlayback] re-sweeps sources instead of reusing the failed one.
  void invalidateWinner(String zmEpisodeUrl) {
    // Also drops a remembered "nothing has this episode": Retry and the
    // player's own source-switch both come through here, and they must get a
    // real sweep rather than the cached no.
    //
    // EVERY category: the keys carry one now, and a caller retrying an episode
    // means "forget what you know about it", not "forget the sub cut".
    bool mine(String k) =>
        k == zmEpisodeUrl || k.startsWith('$zmEpisodeUrl|');
    // BOTH maps, independently. A sweep that found nothing leaves a _noSource
    // entry and no winner at all, so walking _winners alone would clear
    // nothing and Retry would keep answering from the remembered no.
    final winners = _winners.keys.where(mine).toList();
    final misses = _noSource.keys.where(mine).toList();
    for (final k in winners) {
      _winners.remove(k);
    }
    for (final k in misses) {
      _noSource.remove(k);
    }
    if (winners.isNotEmpty || misses.isNotEmpty) {
      debugPrint(
        '[playback] invalidateWinner · $zmEpisodeUrl '
        '(${winners.length} winner(s), ${misses.length} miss(es))',
      );
    }
  }

  /// Drop every cached winner for [c] — the whole show, not one episode.
  ///
  /// Changing a title's source has to come through here. [_winners] is keyed
  /// per EPISODE and [sources] short-circuits on it without consulting the
  /// pin, so switching source left every episode still resolving through the
  /// source that played last: press play and you got the old source's stream.
  /// It cleared itself on restart, which is the only reason it looked
  /// intermittent rather than broken.
  void invalidateShow(ZCanonical c) {
    final prefix = '${ZmodeIds.showUrl(c)}/ep/';
    // Each map walked on its own. A show whose sweep found nothing has a
    // _noSource entry and no winner, so keying the loop off _winners would
    // leave the remembered "no source" in place and the new source would
    // never get asked.
    final winners = _winners.keys.where((k) => k.startsWith(prefix)).toList();
    final misses = _noSource.keys.where((k) => k.startsWith(prefix)).toList();
    // An in-flight resolve was started for the OLD source; letting it settle
    // would write that source straight back into _winners.
    final flights = _inFlight.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in winners) {
      _winners.remove(k);
    }
    for (final k in misses) {
      _noSource.remove(k);
    }
    for (final k in flights) {
      _inFlight.remove(k);
    }
    if (winners.isNotEmpty || misses.isNotEmpty || flights.isNotEmpty) {
      debugPrint(
        '[playback] invalidateShow · $prefix '
        '(${winners.length} winner(s), ${misses.length} miss(es))',
      );
    }
  }

  /// n-th entry in [eps] (1-based), same positional rule as detail playback.
  static Episode? _episodeAtIndex(List<Episode> eps, int n) {
    final i = n - 1;
    if (i < 0 || i >= eps.length) return null;
    return eps[i];
  }

  /// Answered over a method channel by native code, rather than by the JS
  /// runtime on this isolate — which decides whether a probe can run alongside
  /// its neighbours or has to wait its turn.
  static bool _isNativeSource(String id) =>
      id.startsWith('cs:') ||
      id.startsWith('ani:') ||
      id.startsWith('mihon:') ||
      id.startsWith('lnr:');

  /// Every source [probeEach] is going to ask, in the order it will ask them.
  ///
  /// Exposed so a list can show the whole queue up front — a row appearing out
  /// of nowhere reads as a stall, whereas a pending row turning into an answer
  /// reads as progress, and the count tells you how much is left.
  List<({String id, String name})> candidatesForEpisode(String zmEpisodeUrl) {
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p == null) return const [];
    return [
      for (final id in _orderedCandidates(p.show))
        (id: id, name: _sources.displayName(id)),
    ];
  }

  /// One candidate's verdict, as [probeEach] reports it.
  ///
  /// [streams] non-empty means this source can play the episode right now.
  /// [checking] is true for the row emitted BEFORE the work starts, so a list
  /// can show which source is being asked rather than a bare spinner.
  /// Bounded by TIME, not by a count of sources.
  ///
  /// Counting was the wrong dial. Measured on device, most candidates answer
  /// in 0-1ms — they have a remembered miss for this title and cost nothing to
  /// ask. Capping at twelve *sources* therefore spent the whole allowance on
  /// free questions and stopped before the interesting ones, so the viewer had
  /// to keep pressing "Keep checking" to get through a list that would have
  /// finished on its own in seconds.
  ///
  /// [wallClock] bounds the pass instead, which is what actually protects
  /// someone with a hundred sources: cheap ones stay free, and only genuinely
  /// slow ones eat the budget. [skip] lets a caller resume past a stop.
  ///
  /// Each candidate is a real scrape, and JS providers run on this isolate —
  /// so the yield between them is not politeness, it is the only chance the UI
  /// gets to draw the answer that just landed.
  Stream<SourceProbe> probeEach(
    String zmEpisodeUrl, {
    Duration wallClock = const Duration(seconds: 20),
    Set<String> skip = const {},
  }) {
    final out = StreamController<SourceProbe>();
    final clock = Stopwatch()..start();
    var stopped = false;
    bool full() =>
        stopped || out.isClosed || clock.elapsed > wallClock;

    Future<void> run() async {
      final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
      if (p == null) return;
      final t = await _titleLookup(p.show);
      final all = _orderedCandidates(
        p.show,
      ).where((id) => !skip.contains(id)).toList();
      debugPrint(
        '[probe] ── pass start · ${all.length} to ask · '
        'up to ${wallClock.inSeconds}s',
      );

      /// True when this one blew its budget — the JS lane uses that to stop.
      Future<bool> probeOne(String sourceId) async {
        if (full()) return false;
        final name = _sources.displayName(sourceId);
        if (CfSolveNeeded.sourceFlagged(sourceId) ||
            _health.isSkippable(sourceId) ||
            _recentlyOverBudget(sourceId)) {
          if (!out.isClosed) {
            out.add(SourceProbe(sourceId: sourceId, name: name, skipped: true));
          }
          return false;
        }
        // Re-checked here, not just on entry: several probes are in flight at
        // once, and a hit landing while this one was queued means it is no
        // longer wanted.
        if (full()) return false;
        if (!out.isClosed) {
          out.add(SourceProbe(sourceId: sourceId, name: name, checking: true));
        }
        Episode? srcEp;
        SourceMatch? match;
        // Timed and logged per source: without this the probe was invisible in
        // a device log — a ten-second stall showed up as a gap between two
        // unrelated lines, with nothing saying who was being waited on.
        final sw = Stopwatch()..start();
        var how = 'no';
        try {
          // Passive: a survey must never pop the blocking Cloudflare WebView.
          // One challenged source did exactly that and stalled the app for
          // twelve seconds — after its own probe had already been abandoned.
          // Challenged sources are recorded via CfSolveNeeded instead, so the
          // solve can still be offered when the viewer actually picks one.
          (match, srcEp) = await _passively(
            () => _hasEpisode(p, sourceId, t),
          ).timeout(probeBudget);
          how = srcEp != null ? 'HAS' : 'no';
        } on TimeoutException {
          _overBudget[sourceId] = DateTime.now();
          how = 'timeout';
        } catch (e) {
          how = 'error: $e';
        }
        debugPrint(
          '[probe] $sourceId → $how (${sw.elapsedMilliseconds}ms)',
        );
        final timedOut = how == 'timeout';
        if (!out.isClosed) {
          out.add(SourceProbe(
            sourceId: sourceId,
            name: name,
            episodeUrl: srcEp?.url,
            match: match,
          ));
        }
        return timedOut;
      }

      // TWO LANES, because the sources are not alike.
      //
      // CloudStream, Aniyomi and Mihon answer over a method channel — the work
      // happens on a native thread pool, so several at once cost this isolate
      // nothing but the replies. Those go in parallel, a few at a time.
      //
      // JS providers run in flutter_js ON this isolate, and calls to it are
      // deliberately serialized (running them concurrently is what used to
      // SIGABRT the runtime). Those stay one at a time — "parallel" there
      // would not be faster, it would be a crash.
      //
      // The two lanes run together, so a slow JS provider no longer holds up
      // twenty native ones behind it.
      final native = <String>[];
      final js = <String>[];
      for (final id in all) {
        (_isNativeSource(id) ? native : js).add(id);
      }

      // Workers pulling from a shared queue, NOT batches of five: a batch is
      // only as fast as its slowest member, so one source sitting on its whole
      // budget stalled four others that had already answered. A worker that
      // finishes takes the next id immediately.
      var next = 0;
      Future<void> nativeWorker() async {
        while (!full()) {
          if (next >= native.length) return;
          final id = native[next++];
          await probeOne(id);
          await Future<void>.delayed(Duration.zero);
        }
      }

      Future<void> nativeLane() =>
          Future.wait([for (var i = 0; i < 5; i++) nativeWorker()]);

      Future<void> jsLane() async {
        for (final id in js) {
          if (full()) return;
          final timedOut = await probeOne(id);
          // ONE timeout ends this lane for the pass.
          //
          // `.timeout()` abandons the WAIT, not the work: a JS call that blew
          // its budget is still running on the shared runtime, so the next JS
          // probe queues behind it and burns its own budget waiting for a
          // runtime that is still busy. Measured on device: animekai timed out
          // at 5.001s and hianime timed out at 5.001s immediately after —
          // ten seconds to learn nothing, from a source that had answered in
          // 620ms earlier in the same session.
          //
          // The remaining JS sources are left UNASKED rather than reported as
          // misses, and "Keep checking" retries them once the runtime is free.
          if (timedOut) {
            debugPrint(
              '[probe] JS lane stopped — runtime busy after $id timed out',
            );
            return;
          }
          await Future<void>.delayed(Duration.zero);
        }
      }

      await Future.wait([nativeLane(), jsLane()]);
    }

    out.onCancel = () => stopped = true;
    unawaited(
      run().whenComplete(() {
        if (!out.isClosed) out.close();
      }),
    );
    return out.stream;
  }

  /// Streams for [zmEpisodeUrl] from EXACTLY [sourceId] — no sweep, no
  /// remembered winner.
  ///
  /// For callers that already know which source they mean. Downloading is the
  /// one that matters: the record stores the source the user was looking at,
  /// asked for it by name, and got whichever source last PLAYED the episode
  /// instead, because the name was dropped on the way through. Returns an
  /// empty list when that source doesn't have it, rather than quietly
  /// substituting another — a download from a source you didn't choose is the
  /// bug, not the fallback.
  Future<List<VideoSource>> sourcesFrom(
    String zmEpisodeUrl,
    String sourceId, {
    bool fast = false,
    String category = 'sub',
  }) async {
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p == null) return const [];
    final t = await _titleLookup(p.show);
    final (match, ep) = await _hasEpisode(p, sourceId, t, category: category);
    if (match == null || ep == null) {
      debugPrint('[playback] sourcesFrom · $sourceId has no ep ${p.episode}');
      return const [];
    }
    return _sources.sources(ep.url, sourceId: match.sourceId, fast: fast);
  }

  /// [body] with the blocking Cloudflare solver disabled, when the JS provider
  /// manager is available to disable it. A no-op otherwise (tests, TV boot)
  /// rather than a hard dependency — suppression is an optimisation, never a
  /// correctness gate.
  Future<T> _passively<T>(Future<T> Function() body) =>
      sl.isRegistered<ProviderManager>()
      ? sl<ProviderManager>().asPassiveSweep(body)
      : body();

  /// Does [sourceId] LIST this episode? Deliberately stops there.
  ///
  /// The expensive half of resolving a source is the streams: server
  /// enumeration, the extractor round-trips, the host that answers in its own
  /// time. Measured on device, that turned a single probe into three to
  /// thirteen seconds — for a list whose only question is "who has it".
  ///
  /// So this asks the title and the episode list and stops. The answer is
  /// slightly optimistic — a source can list an episode and still have no
  /// working server — but that is the failure the player already handles with
  /// failover and an honest message, and it is worth trading for a list that
  /// answers in well under a second per source.
  Future<(SourceMatch?, Episode?)> _hasEpisode(
    ({ZCanonical show, int episode}) p,
    String sourceId,
    ({String title, String? alt, int? malId}) t, {
    String category = 'sub',
  }) async {
    final match = await _matcher.matchOn(
      p.show,
      sourceId,
      title: t.title,
      altTitle: t.alt,
      malId: t.malId,
    );
    if (match == null) return (null, null);
    final eps = await _sources.episodes(
      match.showUrl,
      sourceId: match.sourceId,
      category: category,
    );
    return (match, _episodeAtIndex(eps, p.episode));
  }

  /// Make [sourceId]'s already-probed result the one playback uses, so opening
  /// the player after a pick doesn't re-resolve anything.
  /// The winner cache holds only (episode url, source id), so a probe that
  /// stopped short of the streams is enough — the player resolves them for the
  /// one source that was picked, which is the work that had to happen anyway.
  Future<void> useProbed(String zmEpisodeUrl, SourceProbe probe) async {
    final url = probe.episodeUrl;
    final m = probe.match;
    if (url == null || m == null) return;
    _noSource.remove(zmEpisodeUrl);
    _winners[zmEpisodeUrl] = (episodeUrl: url, sourceId: m.sourceId);
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p != null && !m.pinned) {
      await _store.rememberLastPlayed(p.show, m.sourceId);
    }
  }

  /// One candidate's whole attempt — title match, episode list, streams — as a
  /// single future, so [perSourceBudget] can cap all three together. Null when
  /// this source simply doesn't have the title or the episode; it throws only
  /// when the source itself failed.
  Future<_Attempt?> _tryCandidate(
    ({ZCanonical show, int episode}) p,
    String sourceId,
    ({String title, String? alt, int? malId}) t, {
    required bool fast,
    required void Function() onTitleMatch,
    String category = 'sub',
  }) async {
    final match = await _matcher.matchOn(
      p.show,
      sourceId,
      title: t.title,
      altTitle: t.alt,
      malId: t.malId,
    );
    if (match == null) {
      debugPrint('[playback] _resolve · $sourceId → no title match');
      return null;
    }
    onTitleMatch();

    final srcEp = _episodeAtIndex(
      await _sources.episodes(
        match.showUrl,
        sourceId: match.sourceId,
        category: category,
      ),
      p.episode,
    );
    if (srcEp == null) {
      debugPrint(
        '[playback] _resolve · $sourceId → episode ${p.episode} not found',
      );
      return null;
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
      return null;
    }
    return _Attempt(match: match, episodeUrl: srcEp.url, streams: streams);
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

    // Position in the incoming list IS the user's Source Priority order (see
    // `orderedCandidates` in zmode_module). Dart's List.sort is only stable
    // below 32 elements — past that it switches to quicksort — and a real
    // library has more candidates than that, so ranking without an explicit
    // positional tiebreak silently scrambled the priority the user set.
    final position = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final sorted = ids.toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : position[a]!.compareTo(position[b]!);
      });
    return sorted;
  }

  int _healthRank(String id) => switch (_health.statusOf(id)) {
    SourceHealth.ok => 0,
    SourceHealth.slow => 1,
    SourceHealth.dead => 2,
  };
}

/// One candidate's successful attempt, before it is promoted to the sweep's
/// answer. Separate from [ResolvedPlayback] because it carries only what the
/// candidate itself produced — the show/episode are the sweep's to add.
class _Attempt {
  const _Attempt({
    required this.match,
    required this.episodeUrl,
    required this.streams,
  });
  final SourceMatch match;
  final String episodeUrl;
  final List<VideoSource> streams;
}

/// One source's answer while [PlaybackResolver.probeEach] walks the list.
class SourceProbe {
  const SourceProbe({
    required this.sourceId,
    required this.name,
    this.pending = false,
    this.checking = false,
    this.skipped = false,
    this.episodeUrl,
    this.match,
  });

  final String sourceId;
  final String name;

  /// Queued but not reached yet. Never emitted by [PlaybackResolver.probeEach]
  /// — the sheet seeds its list with these from [candidatesForEpisode] so the
  /// whole queue is visible from the first frame.
  final bool pending;

  /// Emitted before the work starts, so the row can show what's happening.
  final bool checking;

  /// Never asked: Cloudflare-blocked, marked unhealthy, or over budget too
  /// recently. Reported rather than hidden — "not asked" is not "hasn't got it".
  final bool skipped;

  final String? episodeUrl;
  final SourceMatch? match;

  /// This source lists the episode. Not a promise that it will play — see
  /// [PlaybackResolver._hasEpisode] for why the check stops there.
  bool get hasEpisode => episodeUrl != null;
}
