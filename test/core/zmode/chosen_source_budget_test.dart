import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/provider/js_engine.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

const _show = ZCanonical(ZKind.anime, 'mal:100');
const _ep2 = 'zm://anime/mal:100/ep/2';

/// src-a answers, but slowly. src-b answers at once but has no episode 2.
class _SlowSrc implements SourceRepository {
  _SlowSrc({required this.aDelay, this.bHasEpisode = false});

  final Duration aDelay;

  /// Whether src-b can serve episode 2 — off by default so the budget tests
  /// see a clean failure when src-a is cut off.
  final bool bHasEpisode;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    (id: 'src-a', name: 'Slowpoke'),
    (id: 'src-b', name: 'Quickdraw'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  String displayName(String sourceId) =>
      sourceId == 'src-a' ? 'Slowpoke' : 'Quickdraw';

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async => [
    MediaItem(
      id: sourceId!,
      title: 'FMA',
      url: 'https://$sourceId/show',
      type: ProviderType.anime,
      sourceId: sourceId,
    ),
  ];

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    if (sourceId == 'src-a') {
      await Future<void>.delayed(aDelay);
      return const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ];
    }
    return [
      const Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
      if (bHasEpisode)
        const Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
    ];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => const [VideoSource(url: 'https://a/stream')];
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chosen-budget');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });

  tearDown(() async {
    JsEngine.debugRunsOffUiIsolateOverride = null;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  ({PlaybackResolver r, SourceMatcher m}) build(
    _SlowSrc src, {
    Duration? relaxedBudget,
  }) {
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = PlaybackResolver(
      matcher: matcher,
      sources: src,
      store: store,
      prefs: prefs,
      health: health,
      candidates: (_) => src.loadedSources,
      // Scaled-down stand-ins for 8s, 20s and 25s.
      perSourceBudget: const Duration(milliseconds: 60),
      relaxedBudget: relaxedBudget ?? const Duration(milliseconds: 60),
      chosenBudget: const Duration(milliseconds: 600),
    );
    r.bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
    return (r: r, m: matcher);
  }

  group('a source the viewer picked gets time to answer', () {
    test('pinned, it wins even though it is slower than the normal budget',
        () async {
      // The whole complaint: pick a source you know works, and playback still
      // says nothing is available because 8s elapsed.
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: const Duration(milliseconds: 250));
      final b = build(src);
      await b.m.pinTitleToSource(_show, 'src-a', title: 'FMA');

      final res = await b.r.resolveForPlayback(_ep2);
      expect(res.match.sourceId, 'src-a');
    });

    test('unpinned, the same slow source is still cut off at the short budget',
        () async {
      // The tight budget has to keep applying to everything else, or one slow
      // source in a long list is back to holding up the whole sweep.
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: const Duration(milliseconds: 250));
      final b = build(src);

      await expectLater(
        b.r.resolveForPlayback(_ep2),
        throwsA(isA<EpisodeNotAvailable>()),
      );
    });

    test('where JS still runs on the UI isolate, nothing is extended',
        () async {
      // On Apple the engine is still in-process, so a 25s wait would be 25
      // frozen seconds. The budget must stay tight there.
      JsEngine.debugRunsOffUiIsolateOverride = false;
      final src = _SlowSrc(aDelay: const Duration(milliseconds: 250));
      final b = build(src);
      await b.m.pinTitleToSource(_show, 'src-a', title: 'FMA');

      await expectLater(
        b.r.resolveForPlayback(_ep2),
        throwsA(isA<EpisodeNotAvailable>()),
      );
    });
  });

  test('a sweep that timed out says so, instead of claiming nothing has it',
      () async {
    JsEngine.debugRunsOffUiIsolateOverride = true;
    final src = _SlowSrc(aDelay: const Duration(seconds: 30));
    final b = build(src);

    try {
      await b.r.resolveForPlayback(_ep2);
      fail('expected the sweep to fail');
    } on EpisodeNotAvailable catch (e) {
      expect(
        e.outcomes.any(
          (o) => o.sourceId == 'src-a' && o.reason == SweepReason.timedOut,
        ),
        isTrue,
      );
      expect(sweepFailureDetail(e.outcomes), 'Slowpoke took too long to answer');
    }
  });

  group('leaving stops the candidate the sweep is waiting on', () {
    test('abort returns at once instead of waiting the budget out', () async {
      // The regression: abortSweeps only moved _sweepGen, which the loop reads
      // BETWEEN candidates — so backing out still sat through the one in
      // flight. At the 8s flat budget that was tolerable; once a chosen source
      // got 25s it read as a frozen app (anikoto, measured on device at 25.0s
      // between "trying" and "the viewer left").
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: const Duration(milliseconds: 900));
      final b = build(src);
      await b.m.pinTitleToSource(_show, 'src-a', title: 'FMA');

      final sw = Stopwatch()..start();
      final call = b.r.resolveForPlayback(_ep2);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      b.r.abortSweeps();
      await expectLater(call, throwsA(isA<PlaybackAborted>()));
      sw.stop();

      // The chosen budget here is 600ms; without the fix this could not have
      // returned before it.
      expect(
        sw.elapsedMilliseconds,
        lessThan(400),
        reason: 'waited out the budget instead of leaving when asked',
      );
    });

    test('a sweep nobody aborted still runs to its answer', () async {
      // The no-regression half: the race must not cut a sweep short on its own.
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: const Duration(milliseconds: 250));
      final b = build(src);
      await b.m.pinTitleToSource(_show, 'src-a', title: 'FMA');

      final res = await b.r.resolveForPlayback(_ep2);
      expect(res.match.sourceId, 'src-a');
    });
  });

  group('a source picked by hand is not silently substituted', () {
    test('when the pin fails, the sweep stops instead of playing another',
        () async {
      // The complaint: pin AnimePahe, stare at a spinner for 25s, then watch
      // Netflix start — with nothing said about the swap.
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: const Duration(seconds: 5), bHasEpisode: true);
      final b = build(src);
      await b.m.pinTitleToSource(_show, 'src-a', title: 'FMA');

      // src-b could serve it, and without the guard it would.
      await expectLater(
        b.r.resolveForPlayback(_ep2),
        throwsA(anyOf(isA<EpisodeNotAvailable>(), isA<NoSourceMatch>())),
      );
    });

    test('an UNPINNED slow source still falls through, as it always did',
        () async {
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: const Duration(seconds: 5), bHasEpisode: true);
      final b = build(src); // nothing pinned
      final res = await b.r.resolveForPlayback(_ep2);
      expect(res.match.sourceId, 'src-b');
    });
  });

  group('sweepFailureDetail', () {
    SweepOutcome o(String name, SweepReason r) =>
        (sourceId: name, name: name, reason: r);

    test('stays quiet when every source genuinely answered', () {
      // Nothing to add: the caller's own "not available" line is the truth.
      expect(
        sweepFailureDetail([
          o('A', SweepReason.noTitleMatch),
          o('B', SweepReason.episodeMissing),
          o('C', SweepReason.noStreams),
        ]),
        isNull,
      );
      expect(sweepFailureDetail(const []), isNull);
    });

    test('names one, two, then counts the rest', () {
      expect(
        sweepFailureDetail([o('A', SweepReason.timedOut)]),
        'A took too long to answer',
      );
      expect(
        sweepFailureDetail([
          o('A', SweepReason.timedOut),
          o('B', SweepReason.timedOut),
        ]),
        'A and B took too long to answer',
      );
      expect(
        sweepFailureDetail([
          o('A', SweepReason.timedOut),
          o('B', SweepReason.timedOut),
          o('C', SweepReason.timedOut),
        ]),
        'A and 2 others took too long to answer',
      );
    });

    test('a timeout outranks the quieter reasons', () {
      // Slow is the one the viewer can do something about — retry.
      expect(
        sweepFailureDetail([
          o('A', SweepReason.unhealthy),
          o('B', SweepReason.timedOut),
          o('C', SweepReason.noTitleMatch),
        ]),
        'B took too long to answer',
      );
    });

    test('a Cloudflare check is called what it is', () {
      expect(
        sweepFailureDetail([o('A', SweepReason.cloudflare)]),
        'A needs a Cloudflare check',
      );
    });
  });

  group('a source whose links do not play is swept past', () {
    test('the next resolve picks a different source', () async {
      // The reported shape: cs:4K HDHUB answered One Piece with four streams
      // in 2.3s, then the link itself was dead. The player had nowhere to go
      // and said "every source failed (tried 1)" with 35 sources untouched.
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: Duration.zero, bHasEpisode: true);
      final b = build(src);
      await b.m.pinTitleToSource(_show, 'src-a', title: 'FMA');

      expect((await b.r.resolveForPlayback(_ep2)).match.sourceId, 'src-a');

      // src-a's links turned out to be dead.
      b.r.markSourceUnplayable(_ep2, 'src-a');
      expect(b.r.unplayableCount(_ep2), 1);

      // Even though it is still PINNED, the next resolve moves on.
      expect((await b.r.resolveForPlayback(_ep2)).match.sourceId, 'src-b');
    });

    test('the cached winner goes with it, so nothing replays the dead link',
        () async {
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: Duration.zero, bHasEpisode: true);
      final b = build(src);

      await b.r.resolveForPlayback(_ep2);
      expect(b.r.resolvedSourceId(_ep2), 'src-a');
      b.r.markSourceUnplayable(_ep2, 'src-a');
      expect(b.r.resolvedSourceId(_ep2), isNull);
    });

    test('when nothing is left, the failure says the links were dead', () async {
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: Duration.zero, bHasEpisode: false);
      final b = build(src);

      await b.r.resolveForPlayback(_ep2);
      b.r.markSourceUnplayable(_ep2, 'src-a');

      try {
        await b.r.resolveForPlayback(_ep2);
        fail('expected the sweep to fail');
      } on EpisodeNotAvailable catch (e) {
        expect(
          sweepFailureDetail(e.outcomes),
          'Slowpoke gave links that would not open',
        );
      }
    });

    test('Try again forgives it — invalidateWinner clears the exclusion',
        () async {
      // A dead CDN link is usually temporary, and Retry means "try everything".
      JsEngine.debugRunsOffUiIsolateOverride = true;
      final src = _SlowSrc(aDelay: Duration.zero, bHasEpisode: true);
      final b = build(src);
      await b.m.pinTitleToSource(_show, 'src-a', title: 'FMA');

      await b.r.resolveForPlayback(_ep2);
      b.r.markSourceUnplayable(_ep2, 'src-a');
      expect((await b.r.resolveForPlayback(_ep2)).match.sourceId, 'src-b');

      b.r.invalidateWinner(_ep2);
      expect(b.r.unplayableCount(_ep2), 0);
      expect((await b.r.resolveForPlayback(_ep2)).match.sourceId, 'src-a');
    });
  });

  // THE REPORTED BUG, as a test.
  //
  // "Auto fetch source showing no streams found while searching on all source,
  // then select one individual source and it shows streams." That was not a
  // mystery: an un-chosen source got 8s while a hand-picked one got 25s, so a
  // source answering in ~12s was thrown away by Auto Resolve and kept by a
  // manual pick. Same source, same episode, different patience.
  test('a slow source Auto Resolve used to drop now plays without being picked',
      () async {
    JsEngine.debugRunsOffUiIsolateOverride = true;
    // Answers well past the tight 60ms stand-in for 8s, comfortably inside the
    // 300ms stand-in for the relaxed budget.
    final src = _SlowSrc(aDelay: const Duration(milliseconds: 150));
    final b = build(src, relaxedBudget: const Duration(milliseconds: 300));
    // Nothing pinned, no kind default — this is a plain Auto Resolve sweep.
    final out = await b.r.sources('zm://anime/mal:100/ep/2');
    expect(out, isNotEmpty,
        reason: 'the slow source answered inside the relaxed budget, so Auto '
            'Resolve must accept it — being picked by hand is not what makes '
            'a source work');
  });

  // The other half of the same rule: where provider JS still runs on the UI
  // isolate, waiting really does cost frames, so the tight budget stands and a
  // slow source is still dropped. Patience is only free where it is free.
  test('where JS is on the UI isolate the tight budget still applies', () async {
    JsEngine.debugRunsOffUiIsolateOverride = false;
    final src = _SlowSrc(aDelay: const Duration(milliseconds: 150));
    final b = build(src, relaxedBudget: const Duration(milliseconds: 300));
    // A sweep with nothing left to offer throws rather than returning an
    // empty list — that is how the failure sheet gets a reason to show.
    await expectLater(
      b.r.sources('zm://anime/mal:100/ep/2'),
      throwsA(isA<Exception>()),
      reason: '8s bounded UI freeze, and on that platform it still does, so '
          'the slow source is still dropped',
    );
  });
}
