import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/video_source.dart';
import '../playback/source_health_store.dart';
import '../di/injector.dart';
import '../provider/cf_solve_needed.dart';
import '../provider/js_engine.dart';
import '../provider/provider_manager.dart';
import '../repository/source_repository.dart';
import 'match_store.dart';
import 'source_matcher.dart';
import 'source_order_prefs.dart';
import 'source_score_store.dart';
import 'zmode_ids.dart';
import 'zmode_source_prefs.dart';

/// Why one source did not end the sweep. Recorded for every candidate so a
/// failure can say what actually happened instead of "no source has this".
///
/// The distinction that matters to a viewer is whether a source ANSWERED.
/// [timedOut], [cloudflare], [unhealthy] and [cooldown] mean it never really
/// did — and telling someone an episode does not exist because four sources
/// were slow is simply untrue. [streamsDead] is a source that answered with
/// links that turned out not to play. The rest are real answers.
enum SweepReason {
  timedOut,
  cloudflare,
  unhealthy,
  cooldown,
  failed,
  streamsDead,
  noTitleMatch,
  episodeMissing,
  noStreams,
}

/// One candidate's verdict in a sweep.
typedef SweepOutcome = ({String sourceId, String name, SweepReason reason});

/// A short, true sentence about why a sweep found nothing, or null when the
/// outcomes say nothing the caller doesn't already know.
///
/// Only speaks up for the reasons that leave the question open — a source that
/// was never really asked, or one whose links turned out to be dead. If every
/// source genuinely answered and genuinely lacked the episode, the caller's
/// own message is already the right one.
String? sweepFailureDetail(List<SweepOutcome> outcomes) {
  String names(SweepReason r) {
    final n = outcomes.where((o) => o.reason == r).map((o) => o.name).toList();
    if (n.isEmpty) return '';
    if (n.length == 1) return n.first;
    if (n.length == 2) return '${n[0]} and ${n[1]}';
    return '${n.first} and ${n.length - 1} others';
  }

  final slow = names(SweepReason.timedOut);
  final deadLinks = names(SweepReason.streamsDead);
  final cf = names(SweepReason.cloudflare);
  final cooling = names(SweepReason.cooldown);
  final unwell = names(SweepReason.unhealthy);

  if (slow.isNotEmpty) return '$slow took too long to answer';
  if (deadLinks.isNotEmpty) return '$deadLinks gave links that would not open';
  if (cf.isNotEmpty) return '$cf needs a Cloudflare check';
  if (cooling.isNotEmpty) return '$cooling was skipped after a recent timeout';
  if (unwell.isNotEmpty) return '$unwell is not responding';
  return null;
}

/// Thrown when no installed source can play this metadata episode — either
/// because no source has the title, the episode is missing everywhere, or
/// every source that has it returned no streams.
class EpisodeNotAvailable implements Exception {
  const EpisodeNotAvailable(
    this.canonical,
    this.episode, {
    this.hadTitleMatch = false,
    this.outcomes = const [],
  });
  final ZCanonical canonical;
  final int episode;

  /// True when at least one source matched the show but none could serve this
  /// episode (missing or empty streams).
  final bool hadTitleMatch;

  /// What each candidate actually did. See [sweepFailureDetail].
  final List<SweepOutcome> outcomes;

  @override
  String toString() => hadTitleMatch
      ? 'Episode $episode is not available on any source for $canonical'
      : 'No installed source has $canonical';
}

/// Thrown when a sweep is abandoned because the viewer left playback.
///
/// Its own type on purpose. It is NOT a verdict about the episode: most of the
/// candidates were never asked, so it must not be recorded as a miss and must
/// not be shown to anyone — by the time it is thrown the screen that asked for
/// it is already gone.
class PlaybackAborted implements Exception {
  const PlaybackAborted();

  @override
  String toString() => 'Playback sweep abandoned — the viewer left';
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

    /// Likewise for [chosenSourceBudget].
    Duration? chosenBudget,

    /// Likewise for [relaxedPerSourceBudget].
    Duration? relaxedBudget,

    /// Counts a play against the source that served it. Optional — see
    /// [_scores].
    SourceScoreStore? scores,
  }) : _budget = perSourceBudget ?? defaultPerSourceBudget,
       _chosenBudget = chosenBudget ?? chosenSourceBudget,
       _relaxedBudget =
           relaxedBudget ?? perSourceBudget ?? relaxedPerSourceBudget,
       _matcher = matcher,
       _sources = sources,
       _store = store,
       _prefs = prefs,
       _health = health,
       _candidates = candidates,
       _scores = scores;

  final SourceMatcher _matcher;
  final SourceRepository _sources;
  final MatchStore _store;
  final ZSourcePrefs _prefs;
  final SourceHealthStore _health;
  final List<({String id, String name})> Function(ZKind) _candidates;

  /// Counts a play against the source that served it, so Auto Resolve can rank
  /// on what has actually worked. Optional: every existing test builds this
  /// resolver without one, and a missing store simply means nothing is counted.
  final SourceScoreStore? _scores;
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
  /// 100 seconds of frozen UI, because JS providers ran on the UI isolate and
  /// a second spent in one was a second of frames not drawn.
  ///
  /// That last part is no longer true where [JsEngine.runsOffUiIsolate] — the
  /// wait is now just a wait — so this 8s is now only the fallback for where
  /// it IS still true (Apple, which runs JavaScriptCore in-process). There,
  /// 8s of patience would still be 8s of frozen frames.
  ///
  /// Everywhere else, see [relaxedPerSourceBudget].
  static const Duration defaultPerSourceBudget = Duration(seconds: 8);
  final Duration _budget;

  /// What an un-chosen source gets where the wait costs no frames.
  ///
  /// 8s was never the source's fault. It bounded UI freeze, and once provider
  /// JS moved off the UI isolate it stopped bounding anything except total
  /// sweep length — while still being short enough to throw away a source that
  /// simply answers slowly. That produced the reported bug directly: a source
  /// needing ~12s was cut off by Auto Resolve and reported as having nothing,
  /// then played perfectly the moment the viewer picked it by hand, because a
  /// hand-picked source gets [chosenSourceBudget] instead.
  ///
  /// Same patience for both now, so "Auto Resolve says no, picking it says
  /// yes" cannot happen. Total sweep length is bounded by the source cap and
  /// the waves instead — by asking fewer sources and asking them together,
  /// rather than by giving up on each one early.
  /// How many candidates a sweep asks at once.
  ///
  /// Three, not ten: the sweep stops at the first source that answers, so a
  /// bigger wave spends requests on titles that were about to work anyway.
  /// Three roughly thirds the wait when nothing has the episode while asking
  /// at most two sources more than strictly needed when something does.
  ///
  /// Caveat worth knowing: the bundled JS providers share one QuickJS engine
  /// (`_serialized` in provider_manager.dart), so several of THOSE in one wave
  /// still run one after another. CloudStream, Aniyomi and Mihon sources are
  /// native and genuinely overlap, and they are the bulk of a real library.
  static const int sweepWaveSize = 3;

  static const Duration relaxedPerSourceBudget = Duration(seconds: 20);
  final Duration _relaxedBudget;

  /// What a source the viewer PICKED gets instead — pinned for this title, or
  /// set as the default for the kind. Both are an explicit "use this one", and
  /// cutting that off at 8s is what produced "nothing plays" on a source the
  /// viewer knew was fine, just slow.
  ///
  /// Only applied where provider JS runs off the UI isolate
  /// ([JsEngine.runsOffUiIsolate]). The 8s above was never about the source's
  /// patience — it bounded how long the UI could be frozen. Where that is
  /// still true, a 25s wait would still be 25 frozen seconds, so the tight
  /// budget stands.
  static const Duration chosenSourceBudget = Duration(seconds: 25);
  final Duration _chosenBudget;

  /// The budget for [sourceId] given the sources this viewer chose.
  ///
  /// Where the wait is free (JS off the UI isolate), a chosen source still gets
  /// the most patience, and everything else gets [relaxedPerSourceBudget]
  /// rather than the old 8s. Where it is not free, the tight budget applies to
  /// everything, chosen or not — exactly as before.
  Duration _budgetFor(String sourceId, Set<String> chosen) {
    if (!JsEngine.runsOffUiIsolate) return _budget;
    return chosen.contains(sourceId) ? _chosenBudget : _relaxedBudget;
  }

  /// The sources the viewer explicitly picked for [c] — the per-title pin and
  /// the kind-wide default. NOT `lastPlayed`: that is the app's own memory of
  /// a successful Auto Resolve, not a choice anybody made.
  Set<String> _chosenSources(ZCanonical c) => {
    ?_matcher.pinnedSource(c),
    ?_prefs.get(c.kind),
  };

  /// Tighter than [_budget], because the two are asking different questions.
  /// Playback is worth waiting 8s for — it is the thing you asked for. A
  /// browse list is not: a source that cannot say whether it lists an episode
  /// within 5 seconds is not the one you are about to pick.
  static const Duration probeBudget = Duration(seconds: 5);

  /// Sources that blew [perSourceBudget], and when. Without this the very next
  /// automatic sweep (next episode, probe, Home re-ask) pays the same 38
  /// seconds again — which is exactly what the device log showed, twice in a
  /// row for the same source.
  ///
  /// Cleared by [invalidateWinner] / [invalidateShow] when the viewer
  /// explicitly asks to play (episode tap, Retry). The cooldown is only for
  /// background / follow-on work — a tap means "try again".
  ///
  /// Deliberately NOT [SourceHealthStore]: a timeout there is recorded as
  /// "alive but slow" on purpose, so a slow source keeps appearing in search
  /// results (see its `record`). This is a playback-only, session-only memory
  /// with its own short cooldown, so nothing about search changes.
  final Map<String, DateTime> _overBudget = {};
  static const Duration overBudgetCooldown = Duration(minutes: 10);

  /// Sources whose links were handed over and then would not play, per
  /// `zm://…|category`. A source can answer a sweep perfectly and still be
  /// useless: a dead CDN link resolves in two seconds and fails in the player.
  /// Without this the very next resolve hands back the same dead link, so the
  /// player had nowhere to go and said "every source failed" having asked
  /// exactly one.
  ///
  /// Episode-scoped and session-only. Cleared by [invalidateWinner], so an
  /// episode tap or Retry gives every source another chance.
  final Map<String, Set<String>> _unplayable = {};

  /// Records that [sourceId]'s links did not play for this episode, and drops
  /// it as the cached winner so the next resolve sweeps past it.
  ///
  /// Deliberately NOT [invalidateWinner]: that clears the very memory this is
  /// trying to write, and the next sweep would pick the same dead source.
  void markSourceUnplayable(
    String zmEpisodeUrl,
    String sourceId, {
    String category = 'sub',
  }) {
    final key = _winKey(zmEpisodeUrl, category);
    (_unplayable[key] ??= <String>{}).add(sourceId);
    _winners.remove(key);
    _noSource.remove(key);
    debugPrint(
      '[playback] markSourceUnplayable · $sourceId for $zmEpisodeUrl '
      '($category) — ${_unplayable[key]!.length} now excluded',
    );
  }

  /// How many sources have been tried and found unplayable for this episode.
  /// The player says so when it finally gives up.
  int unplayableCount(String zmEpisodeUrl, {String category = 'sub'}) =>
      _unplayable[_winKey(zmEpisodeUrl, category)]?.length ?? 0;

  /// Bumped by [abortSweeps]. A sweep captures this before its loop and stops
  /// as soon as it no longer matches.
  int _sweepGen = 0;

  /// Stop the playback sweeps that are running right now, at their next
  /// candidate. Called when the viewer leaves the player.
  ///
  /// A sweep walks every installed source at up to [defaultPerSourceBudget]
  /// each, and nothing used to end it early. `.timeout` only stops WAITING:
  /// the JS call underneath keeps the single provider queue — and with it the
  /// UI isolate — busy until its own 15s limit. So backing out while the sweep
  /// was still going left every remaining candidate queueing up behind a
  /// screen nobody could touch, which is what "the app froze" was.
  ///
  /// The candidate already in flight cannot be called back; it finishes either
  /// way. This stops the ones after it, which is where the time went.
  ///
  /// Playback sweeps only. A filtered sweep (downloading) is nobody's
  /// foreground wait — closing the player must not cancel a download.
  void abortSweeps() {
    _sweepGen++;
    // Moving the generation only stops the NEXT candidate — the loop reads it
    // between candidates. The one already in flight was still waited out, up
    // to its whole budget, and at the 25s a chosen source gets that reads as a
    // frozen app. Waking the sweep is what makes leaving immediate.
    if (!_abortSignal.isCompleted) _abortSignal.complete();
    // Fresh signal, so a sweep started after this one isn't born aborted.
    _abortSignal = Completer<void>();
  }

  /// Completed by [abortSweeps] to wake a sweep blocked on a candidate.
  /// Rotated there, so each abort only wakes the sweeps that were running.
  Completer<void> _abortSignal = Completer<void>();

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
    // Read FIRST, before any await. Taken after one and it reads whatever the
    // abort already set, so the sweep it was meant to stop never sees a change
    // and runs to the end — which is the bug, silently reintroduced.
    final gen = _sweepGen;
    // Derived ONCE per sweep, not per candidate: every `then` registers a
    // listener on the completer, and one per candidate would pile up 37 of
    // them each sweep on a signal that usually never fires.
    final abortFuture = _abortSignal.future.then<_Attempt?>((_) => null);
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
    // The source the viewer pinned to THIS title by hand — stronger than the
    // mode-wide preference in [_chosenSources], and the only one that stops
    // the sweep below.
    final pinned = _matcher.pinnedSource(p.show);
    final ordered = _orderedCandidates(p.show);
    debugPrint(
      '[playback] _resolve · ${ordered.length} ordered candidates '
      '(${ordered.join(", ")})',
    );
    if (ordered.isEmpty) {
      debugPrint('[playback] _resolve → NoSourceMatch (no candidates)');
      throw NoSourceMatch(p.show);
    }

    final chosen = _chosenSources(p.show);
    final dead = _unplayable[_winKey(zmEpisodeUrl, category)] ?? const <String>{};
    final outcomes = <SweepOutcome>[];
    void note(String sourceId, SweepReason reason) => outcomes.add((
      sourceId: sourceId,
      name: _sources.displayName(sourceId),
      reason: reason,
    ));

    var hadTitleMatch = false;

    // One candidate, start to finish. Lifted out of the loop VERBATIM so the
    // sweep can run several at once without the per-source rules changing: the
    // try/catch is still per candidate, so one source throwing ("no sources in
    // response") or hanging cannot kill the others.
    Future<_Attempt?> ask(String sourceId) async {
      debugPrint('[playback] _resolve · trying $sourceId');
      _Attempt? attempt;
      final budget = _budgetFor(sourceId, chosen);
      try {
        final call = _tryCandidate(
          p,
          sourceId,
          t,
          fast: fast,
          category: category,
          onTitleMatch: () => hadTitleMatch = true,
          onMiss: (reason) => note(sourceId, reason),
        ).timeout(budget);
        if (accept == null) {
          // Stop WAITING when the viewer leaves. The request underneath is not
          // cancellable, so it finishes in the background and its answer is
          // dropped — exactly what already happens to an over-budget one.
          attempt = await Future.any<_Attempt?>([call, abortFuture]);
          // The loser still completes. Swallow it, or the TimeoutException
          // nobody is waiting for surfaces as an unhandled async error.
          if (attempt == null) {
            unawaited(call.then<void>((_) {}, onError: (_) {}));
          }
        } else {
          // A filtered sweep (downloading) is nobody's foreground wait, and
          // abortSweeps deliberately leaves it alone — see its doc. Closing
          // the player must not cancel a download.
          attempt = await call;
        }
      } on TimeoutException {
        _overBudget[sourceId] = DateTime.now();
        note(sourceId, SweepReason.timedOut);
        debugPrint(
          '[playback] _resolve · $sourceId → over ${budget.inSeconds}s '
          'budget, skipping it for ${overBudgetCooldown.inMinutes}m',
        );
      } catch (e) {
        note(sourceId, SweepReason.failed);
        debugPrint(
          '[playback] _resolve · $sourceId → error during resolution: $e',
        );
      }
      return attempt;
    }
    // Walked in WAVES rather than one at a time. A sweep that finds nothing
    // used to be the sum of every candidate's wait; now it is the sum of each
    // wave's slowest member, which is what a failing Play tap actually costs.
    //
    // Deliberately small. The sweep stops at the first source that answers, so
    // a wave of ten would fire ten requests where one would have done on every
    // title that works — paying on the common case to speed up the rare one.
    // Three is enough to cut the wait meaningfully and small enough that the
    // waste is a rounding error.
    //
    // Results are read back in CANDIDATE order, never completion order: the
    // list is the viewer's own priority, and letting whichever source answers
    // first win would quietly replace their ordering with a race.
    outer:
    for (var start = 0; start < ordered.length; start += sweepWaveSize) {
      // Once per wave rather than once per candidate. A wave already in flight
      // cannot be recalled — the requests underneath are not cancellable — so
      // leaving stops the NEXT wave, not this one. That is the same bargain as
      // before, just measured in threes.
      if (accept == null && gen != _sweepGen) {
        debugPrint(
          '[playback] _resolve · abandoned before wave at $start — '
          'the viewer left',
        );
        throw const PlaybackAborted();
      }

      // The cheap, synchronous rules first, so a skipped source never occupies
      // a slot in the wave. Each still notes its own reason, and still only
      // for candidates the sweep actually reached — pre-filtering the whole
      // list would report sources it never got to.
      final wave = <String>[];
      for (final sourceId in ordered.skip(start).take(sweepWaveSize)) {
        // Asked already this episode, and its links would not play. Handing
        // them back a second time is how "every source failed (tried 1)"
        // happened with twenty more sources sitting untouched.
        if (dead.contains(sourceId)) {
          debugPrint(
            '[playback] _resolve · skip $sourceId (its links did not play)',
          );
          note(sourceId, SweepReason.streamsDead);
          continue;
        }
        if (CfSolveNeeded.sourceFlagged(sourceId)) {
          debugPrint('[playback] _resolve · skip $sourceId (CF blocked)');
          note(sourceId, SweepReason.cloudflare);
          continue;
        }
        if (_health.isSkippable(sourceId)) {
          debugPrint('[playback] _resolve · skip $sourceId (unhealthy)');
          note(sourceId, SweepReason.unhealthy);
          continue;
        }
        if (_recentlyOverBudget(sourceId)) {
          debugPrint(
            '[playback] _resolve · skip $sourceId (over budget recently)',
          );
          note(sourceId, SweepReason.cooldown);
          continue;
        }
        wave.add(sourceId);
      }
      if (wave.isEmpty) continue;

      // `ask` never throws — every failure inside it is caught and returns
      // null — so one bad source in a wave cannot take the others down.
      final answers = await Future.wait([for (final id in wave) ask(id)]);

      // Again on the way out, not only on the way in. Every candidate in the
      // wave races the abort signal and comes back null the moment it fires,
      // so the wave itself ends promptly — but if this was the LAST wave the
      // loop would then fall through to the bottom and report "nothing has
      // this episode", which is not what happened. The viewer left.
      if (accept == null && gen != _sweepGen) {
        debugPrint(
          '[playback] _resolve · abandoned mid-wave at $start — '
          'the viewer left',
        );
        throw const PlaybackAborted();
      }

      for (var i = 0; i < wave.length; i++) {
        final sourceId = wave[i];
        final attempt = answers[i];
      if (attempt == null) {
        // A source the viewer PICKED by hand is not a candidate among others.
        // Walking past it to whatever answers next meant pinning AnimePahe and
        // silently getting Netflix 25 seconds later — the substitution was
        // never mentioned, so it read as the pin being ignored. Stop here and
        // let the failure say what happened to the source they chose.
        //
        // Playback only (accept == null): a download sweep is looking for a
        // file any source can provide, not honouring a viewing choice. And
        // only when it FAILED — a pin that answers still hands off to the
        // player's own dead-link failover, which is a different question.
        // gen check first: the viewer LEAVING is not the pin failing, and the
        // top of the loop still has to throw PlaybackAborted for it.
        if (accept == null && sourceId == pinned && gen == _sweepGen) {
          debugPrint(
            '[playback] _resolve · $sourceId was pinned by hand and did not '
            'answer — not substituting another source',
          );
          // The whole sweep, not just this wave: the point is that no OTHER
          // source gets substituted, and the rest of the wave is other
          // sources. Their answers are discarded with the loop.
          break outer;
        }
        continue;
      }

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
        await _scores?.bump(attempt.match.sourceId);
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
      throw EpisodeNotAvailable(
        p.show,
        p.episode,
        hadTitleMatch: true,
        outcomes: outcomes,
      );
    }
    debugPrint(
      '[playback] _resolve → NoSourceMatch · '
      '${sweepFailureDetail(outcomes) ?? "every source answered"}',
    );
    throw NoSourceMatch(p.show, outcomes: outcomes);
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
  ///
  /// Also clears over-budget cooldowns: an episode tap / Retry is the viewer
  /// asking to try again, so a source that timed out on the previous attempt
  /// must be eligible. Background sweeps keep the cooldown until this runs.
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
    for (final k in _unplayable.keys.where(mine).toList()) {
      _unplayable.remove(k);
    }
    final clearedBudget = _overBudget.isNotEmpty;
    if (clearedBudget) _overBudget.clear();
    if (winners.isNotEmpty || misses.isNotEmpty || clearedBudget) {
      debugPrint(
        '[playback] invalidateWinner · $zmEpisodeUrl '
        '(${winners.length} winner(s), ${misses.length} miss(es)'
        '${clearedBudget ? ', over-budget cleared' : ''})',
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
    // Source switch / CF solve — same "try again" intent as an episode tap.
    final clearedBudget = _overBudget.isNotEmpty;
    if (clearedBudget) _overBudget.clear();
    if (winners.isNotEmpty ||
        misses.isNotEmpty ||
        flights.isNotEmpty ||
        clearedBudget) {
      debugPrint(
        '[playback] invalidateShow · $prefix '
        '(${winners.length} winner(s), ${misses.length} miss(es)'
        '${clearedBudget ? ', over-budget cleared' : ''})',
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
      await _scores?.bump(m.sourceId);
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
    required void Function(SweepReason) onMiss,
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
      onMiss(SweepReason.noTitleMatch);
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
      onMiss(SweepReason.episodeMissing);
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
      onMiss(SweepReason.noStreams);
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
    // Bounded by the SAME number the Source Priority screen shows. It used to
    // cap only the title-match sweep, so "Try the top 3 sources" still asked
    // all 32 here — the setting meant one thing on that screen and another in
    // the player, which makes it not a setting.
    //
    // A pinned source and the last one that played rank 0 and 1 above, so the
    // sources most likely to work are inside any cap, however small.
    //
    // The cost, deliberately taken: set it low and if those few serve dead
    // links the episode does not play, even though a source further down
    // would have. The failure sheet says only the top sources were checked,
    // and the slider is the fix. A hidden floor here would put the lie back.
    return sorted.take(_sweepCap(c.kind)).toList();
  }

  /// How many sources a sweep may walk, from the user's Source Priority
  /// setting. Falls back to the whole list where that store is not registered
  /// — several tests build this resolver without DI, and bounding them to a
  /// number they never set would change what they are testing.
  int _sweepCap(ZKind kind) => sl.isRegistered<SourceOrderPrefs>()
      ? sl<SourceOrderPrefs>().cap(kind)
      : 1 << 30;

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
