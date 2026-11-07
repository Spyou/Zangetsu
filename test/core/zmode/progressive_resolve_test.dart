import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

/// Progressive resolve yields the first genuine hit without awaiting the
/// whole sweep. Uses the same fakes as playback_resolver_test.dart:
/// two sources, one fast with streams, one slow.
void main() {
  const show = ZCanonical(ZKind.anime, 'mal:100');
  const ep2 = 'zm://anime/mal:100/ep/2';

  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;
  late SourceScoreStore scores;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('progressive-resolve');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    scores = await SourceScoreStore.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  PlaybackResolver resolver({
    required SourceRepository sources,
    required SourceMatcher matcher,
    String? preferred,
    Duration? budget,
    List<({String id, String name})>? candidates,
  }) {
    if (preferred != null) prefs.set(show.kind, preferred);
    final r = PlaybackResolver(
      matcher: matcher,
      sources: sources,
      store: store,
      prefs: prefs,
      health: health,
      candidates: (_) =>
          candidates ?? [(id: 'src-a', name: 'A'), (id: 'src-b', name: 'B')],
      perSourceBudget: budget,
      scores: scores,
    );
    r.bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
    return r;
  }

  SourceMatcher matcherFor(SourceRepository src) => SourceMatcher(
    sources: src,
    store: store,
    prefs: prefs,
    candidates: (_) => (src as _ProgSrc).loadedSources,
  );

  group('remembered show source', () {
    const ep1 = 'zm://anime/mal:100/ep/1';

    Future<void> rememberA() async {
      await store.save(
        show,
        const SourceMatch(
          sourceId: 'src-a',
          showUrl: 'https://a/show',
          showId: 'a',
          showTitle: 'FMA',
          pinned: false,
        ),
      );
      await store.rememberLastPlayed(show, 'src-a');
    }

    for (final progressive in [true, false]) {
      test(
        'episode 2 asks only the previous source: progressive=$progressive',
        () async {
          final src = _ProgSrc.fastSlow(
            aSourcesDelay: Duration.zero,
            bSourcesDelay: Duration.zero,
          );
          final r = resolver(sources: src, matcher: matcherFor(src));
          if (progressive) {
            await r.resolveProgressive(ep1).toList();
          } else {
            await r.sources(ep1, fast: true);
          }
          expect(store.lastPlayed(show), 'src-a');
          src.log.clear();
          if (progressive) {
            final events = await r.resolveProgressive(ep2).toList();
            expect(events.last.match.sourceId, 'src-a');
            expect(events.last.done, isTrue);
          } else {
            expect(await r.sources(ep2, fast: true), isNotEmpty);
          }
          expect(src.log, [
            'episodes:https://a/show:src-a',
            'sources:https://a/2:src-a',
          ]);
        },
      );
    }

    test(
      'missing next episode falls back instead of repeating episode 1',
      () async {
        await rememberA();
        final src = _ProgSrc.fastSlow(
          aHasEp2: false,
          aSourcesDelay: Duration.zero,
          bSourcesDelay: Duration.zero,
        );
        final r = resolver(sources: src, matcher: matcherFor(src));
        final events = await r.resolveProgressive(ep2).toList();
        expect(events.last.match.sourceId, 'src-b');
        expect(
          src.log.where((e) => e == 'episodes:https://a/show:src-a'),
          hasLength(1),
        );
        expect(src.log, isNot(contains('sources:https://a/1:src-a')));
        expect(src.log, contains('sources:https://b/2:src-b'));
      },
    );

    for (final kind in [ZKind.movie, ZKind.tv]) {
      test('remembered source is reused for $kind titles', () async {
        const match = SourceMatch(
          sourceId: 'src-a',
          showUrl: 'https://a/show',
          showId: 'a',
          showTitle: 'FMA',
          pinned: false,
        );
        final title = ZCanonical(kind, 'tmdb:100');
        await store.save(title, match);
        await store.rememberLastPlayed(title, 'src-a');
        final src = _ProgSrc.fastSlow(
          aSourcesDelay: Duration.zero,
          bSourcesDelay: Duration.zero,
        );
        final r = resolver(sources: src, matcher: matcherFor(src));
        await r.resolveProgressive(ZmodeIds.episodeUrl(title, 1)).toList();
        expect(src.log, [
          'episodes:https://a/show:src-a',
          'sources:https://a/1:src-a',
        ]);
      });
    }

    test('remembered source stays scoped to its own title', () async {
      await rememberA();
      const otherAnime = ZCanonical(ZKind.anime, 'mal:101');
      const movie = ZCanonical(ZKind.movie, 'mal:100');
      expect(store.lastPlayed(otherAnime), isNull);
      expect(store.lastPlayed(movie), isNull);
      expect(store.get(movie, 'src-a'), isNull);
      final src = _ProgSrc.fastSlow(
        aSourcesDelay: Duration.zero,
        bSourcesDelay: Duration.zero,
      );
      final r = resolver(sources: src, matcher: matcherFor(src));
      await r.resolveProgressive(ZmodeIds.episodeUrl(otherAnime, 1)).toList();
      expect(src.log, contains('search:src-b'));
      expect(src.log, contains('sources:https://b/1:src-b'));
      expect(store.lastPlayed(show), 'src-a');
    });

    test('manual source choice overrides the remembered source', () async {
      await rememberA();
      final src = _ProgSrc.fastSlow(
        aSourcesDelay: Duration.zero,
        bSourcesDelay: Duration.zero,
      );
      await prefs.set(show.kind, 'src-b');
      final r = resolver(sources: src, matcher: matcherFor(src));
      final events = await r.resolveProgressive(ep2).toList();
      expect(events.last.match.sourceId, 'src-b');
      expect(src.log.any((e) => e.endsWith('src-a')), isFalse);
    });

    test(
      'explicit Auto Resolve searches again after a remembered match',
      () async {
        await rememberA();
        final src = _ProgSrc.fastSlow(
          aSourcesDelay: Duration.zero,
          bSourcesDelay: Duration.zero,
        );
        final matcher = matcherFor(src);
        final r = resolver(sources: src, matcher: matcher);
        matcher.bindSourceChanged(r.invalidateShow);
        await matcher.clearAuto(show);
        await r.resolveProgressive(ep2).toList();
        expect(src.log, contains('sources:https://b/2:src-b'));
      },
    );

    test('uninstalled remembered source is ignored', () async {
      await rememberA();
      final src = _ProgSrc.fastSlow(bSourcesDelay: Duration.zero);
      final r = resolver(
        sources: src,
        matcher: matcherFor(src),
        candidates: [(id: 'src-b', name: 'B')],
      );
      final events = await r.resolveProgressive(ep2).toList();
      expect(events.last.match.sourceId, 'src-b');
      expect(src.log.any((e) => e.endsWith('src-a')), isFalse);
    });

    test('failed playback source is skipped on fallback', () async {
      await rememberA();
      final src = _ProgSrc.fastSlow(bSourcesDelay: Duration.zero);
      final r = resolver(sources: src, matcher: matcherFor(src));
      r.markSourceUnplayable(ep2, 'src-a');
      final events = await r.resolveProgressive(ep2).toList();
      expect(events.last.match.sourceId, 'src-b');
      expect(src.log.any((e) => e.endsWith('src-a')), isFalse);
    });

    test(
      'remembered title still requests the selected audio category',
      () async {
        await rememberA();
        final src = _ProgSrc.fastSlow(
          aSourcesDelay: Duration.zero,
          bSourcesDelay: Duration.zero,
        );
        final r = resolver(sources: src, matcher: matcherFor(src));
        await r.resolveProgressive(ep2, category: 'dub').toList();
        expect(src.categories, ['dub']);
        expect(r.resolvedSourceId(ep2), isNull);
        expect(r.resolvedSourceId(ep2, category: 'dub'), 'src-a');
      },
    );

    test(
      'download filtering does not replace the remembered playback source',
      () async {
        await rememberA();
        final src = _ProgSrc.fastSlow(
          aSourcesDelay: Duration.zero,
          bSourcesDelay: Duration.zero,
        );
        final r = resolver(sources: src, matcher: matcherFor(src));
        final result = await r.resolveForPlayback(
          ep2,
          accept: (streams) =>
              streams.any((s) => s.url.startsWith('https://b/')),
        );
        expect(result.match.sourceId, 'src-b');
        expect(store.lastPlayed(show), 'src-a');
        expect(r.resolvedSourceId(ep2), isNull);
      },
    );
  });

  group('resolveProgressive', () {
    test(
      'TV stops after the winning wave without starting more sources',
      () async {
        final src = _ProgSrc.fastSlow(
          bSourcesDelay: const Duration(milliseconds: 100),
        );
        final r = resolver(
          sources: src,
          matcher: matcherFor(src),
          candidates: [
            (id: 'src-a', name: 'A'),
            (id: 'src-b', name: 'B'),
            (id: 'src-c', name: 'C'),
            (id: 'src-d', name: 'D'),
          ],
        );

        final events = await r
            .resolveProgressive(ep2, stopAfterFirstWave: true)
            .toList();
        expect(events.last.done, isTrue);
        expect(events.last.streams.length, 5);
        expect(src.log, isNot(contains('search:src-d')));
      },
    );

    test('default keeps later waves for phone playback', () async {
      final src = _ProgSrc.fastSlow(
        bSourcesDelay: const Duration(milliseconds: 100),
      );
      final r = resolver(
        sources: src,
        matcher: matcherFor(src),
        candidates: [
          (id: 'src-a', name: 'A'),
          (id: 'src-b', name: 'B'),
          (id: 'src-c', name: 'C'),
          (id: 'src-d', name: 'D'),
        ],
      );

      await r.resolveProgressive(ep2).toList();
      expect(src.log, contains('search:src-d'));
    });

    test('yields first hit before slow source answers', () async {
      // Fake setup mirrors playback_resolver_test.dart's resolver harness:
      // source "fast" answers 2 streams in 50ms, source "slow" answers
      // 3 streams after 5s. Collect EVERY event: the first must land well
      // before the slow source answers, the stream ends with done.
      final src = _ProgSrc.fastSlow();
      final r = resolver(sources: src, matcher: matcherFor(src));
      final Stream<ProgressiveResolve> stream = r.resolveProgressive(ep2);
      final events = <ProgressiveResolve>[];
      final sw = Stopwatch()..start();
      var firstAtMs = -1;
      await for (final e in stream) {
        if (events.isEmpty) firstAtMs = sw.elapsedMilliseconds;
        events.add(e);
      }
      expect(
        firstAtMs,
        lessThan(2000),
        reason: 'first hit must not wait for the 5s slow source',
      );
      expect(events.length, 3, reason: 'fast hit, slow hit, done');
      expect(events.first.match.sourceId, 'src-a');
      expect(events.first.streams.length, 2);
      expect(events.first.done, isFalse);
      expect(events[1].match.sourceId, 'src-b');
      // Cumulative: src-a's 2 plus src-b's 3, in candidate order.
      expect(events[1].streams.length, 5);
      expect(events.last.done, isTrue);
      // The done event carries the union in candidate order, not the last
      // hit alone — the binding constraint with the full resolve.
      expect(events.last.streams.map((s) => s.url).toList(), [
        'https://a/s1',
        'https://a/s2',
        'https://b/s1',
        'https://b/s2',
        'https://b/s3',
      ]);
      expect(src.fastFlags, everyElement(isTrue));
      // Winner bookkeeping runs on the FIRST hit only: the late arrival must
      // not overwrite last-played or collect a score bump.
      expect(store.lastPlayed(show), 'src-a');
      expect(scores.plays('src-a'), 1);
      expect(scores.plays('src-b'), 0);
    });

    test('replays the cached winner immediately without re-sweeping', () async {
      // First play populates the winner cache; the replay must answer from
      // it — one immediate done event on the winner's streams, no sweep.
      final src = _ProgSrc.fastSlow(
        bSourcesDelay: const Duration(milliseconds: 300),
      );
      final r = resolver(sources: src, matcher: matcherFor(src));
      await r.resolveProgressive(ep2).toList();
      src.log.clear();
      final sw = Stopwatch()..start();
      final events = await r.resolveProgressive(ep2).toList();
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(events.length, 1);
      expect(events.single.done, isTrue);
      expect(events.single.match.sourceId, 'src-a');
      expect(events.single.streams.map((s) => s.url).toList(), [
        'https://a/s1',
        'https://a/s2',
      ]);
      expect(src.log, ['sources:https://a/2:src-a']);
    });

    test('aborts an in-flight cached winner lookup immediately', () async {
      final src = _ProgSrc.fastSlow(bSourcesDelay: Duration.zero);
      final r = resolver(sources: src, matcher: matcherFor(src));
      await r.resolveProgressive(ep2).toList();
      src.log.clear();
      src.aSourcesDelay = const Duration(seconds: 5);

      final sw = Stopwatch()..start();
      final pending = r.resolveProgressive(ep2).toList();
      Future<void>.delayed(const Duration(milliseconds: 50), r.abortSweeps);

      await expectLater(pending, throwsA(isA<PlaybackAborted>()));
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason: 'leaving must not wait for the provider lookup to return',
      );
    });

    test('yields in candidate order when the early source is slower', () async {
      // Candidate order beats completion order: src-b answers in 50ms but
      // must wait behind src-a (400ms). Under completion-order yield the
      // first event would be src-b.
      final src = _ProgSrc.fastSlow(
        aSourcesDelay: const Duration(milliseconds: 400),
        bSourcesDelay: const Duration(milliseconds: 50),
      );
      final r = resolver(sources: src, matcher: matcherFor(src));
      final events = await r.resolveProgressive(ep2).toList();
      expect(events.length, 3, reason: 'slow-early hit, fast-late hit, done');
      expect(events.first.match.sourceId, 'src-a');
      expect(events.first.streams.length, 2);
      expect(events[1].match.sourceId, 'src-b');
      expect(events.last.done, isTrue);
      expect(events.last.streams.map((s) => s.url).toList(), [
        'https://a/s1',
        'https://a/s2',
        'https://b/s1',
        'https://b/s2',
        'https://b/s3',
      ]);
    });

    test('pinned source is the only source resolved for playback', () async {
      // A hand-picked source owns the playback request: do not sweep the
      // remaining providers for extra links after the chosen source succeeds.
      final src = _ProgSrc.fastSlow();
      await store.pin(
        show,
        const SourceMatch(
          sourceId: 'src-a',
          showUrl: 'https://a/show',
          showId: 'a',
          showTitle: 'FMA',
          pinned: true,
        ),
      );
      final r = resolver(sources: src, matcher: matcherFor(src));
      final events = await r.resolveProgressive(ep2).toList();
      expect(events, hasLength(1));
      expect(events.single.match.sourceId, 'src-a');
      expect(events.single.done, isTrue);
      expect(
        src.log,
        everyElement(endsWith(':src-a')),
        reason: 'a hand-picked source must not query any other provider',
      );
    });

    test(
      'explicit kind source is the only source resolved for playback',
      () async {
        final src = _ProgSrc.fastSlow();
        await prefs.set(show.kind, 'src-a');
        final r = resolver(sources: src, matcher: matcherFor(src));

        final events = await r.resolveProgressive(ep2).toList();

        expect(events, hasLength(1));
        expect(events.single.match.sourceId, 'src-a');
        expect(events.single.done, isTrue);
        expect(
          src.log,
          everyElement(endsWith(':src-a')),
          reason:
              'an explicit source preference must not query other providers',
        );
      },
    );

    test('pinned source failing is never substituted', () async {
      // The load-bearing half of the pin rule: the pinned source lacks the
      // episode, so the stream ends with the full sweep's verdict instead
      // of handing over the other source's streams.
      final src = _ProgSrc.fastSlow(aHasEp2: false);
      await store.pin(
        show,
        const SourceMatch(
          sourceId: 'src-a',
          showUrl: 'https://a/show',
          showId: 'a',
          showTitle: 'FMA',
          pinned: true,
        ),
      );
      final r = resolver(sources: src, matcher: matcherFor(src));
      await expectLater(
        r.resolveProgressive(ep2),
        emitsError(isA<EpisodeNotAvailable>()),
      );
      expect(
        src.log.where((l) => l.endsWith(':src-b')),
        isEmpty,
        reason: 'src-b answered behind the pinned failure and must be dropped',
      );
    });

    test('slow pinned miss is never substituted by a fast hit', () async {
      // The pin verdict gates the wave: src-b answers in 50ms but is not
      // even asked until the pinned src-a (300ms miss) answers — so no
      // non-pinned hit can slip out first, and the stream ends with the
      // verdict and zero events.
      final src = _ProgSrc.fastSlow(
        aHasEp2: false,
        aEpisodesDelay: const Duration(milliseconds: 300),
        bSourcesDelay: const Duration(milliseconds: 50),
      );
      await store.pin(
        show,
        const SourceMatch(
          sourceId: 'src-a',
          showUrl: 'https://a/show',
          showId: 'a',
          showTitle: 'FMA',
          pinned: true,
        ),
      );
      final r = resolver(sources: src, matcher: matcherFor(src));
      final events = <ProgressiveResolve>[];
      Object? error;
      try {
        await for (final e in r.resolveProgressive(ep2)) {
          events.add(e);
        }
      } catch (e) {
        error = e;
      }
      expect(error, isA<EpisodeNotAvailable>());
      expect(events, isEmpty, reason: 'pinned miss yields nothing, ever');
      expect(
        src.log.where((l) => l.endsWith(':src-b')),
        isEmpty,
        reason: 'src-b was never asked behind the pinned miss',
      );
    });

    test('leaving drops late arrivals (generation guard)', () async {
      // The viewer leaves right after first paint: the slow source's late
      // arrival is dropped and the stream ends with PlaybackAborted,
      // the same signal the full sweep throws.
      final src = _ProgSrc.fastSlow();
      final r = resolver(sources: src, matcher: matcherFor(src));
      final Stream<ProgressiveResolve> stream = r.resolveProgressive(ep2);
      final events = <ProgressiveResolve>[];
      Object? error;
      try {
        await for (final e in stream) {
          events.add(e);
          r.abortSweeps(); // the viewer pressed back
        }
      } catch (e) {
        error = e;
      }
      expect(
        events.length,
        1,
        reason: 'only the first paint landed before leaving',
      );
      expect(error, isA<PlaybackAborted>());
    });
  });
}

/// Same construction pattern as playback_resolver_test.dart's _SweepSrc:
/// two candidates, per-source episode lists, per-source streams.
/// Timing is the only addition: "fast" (src-a) answers 2 streams in 50ms,
/// "slow" (src-b) answers 3 streams after 5s.
class _ProgSrc implements SourceRepository {
  _ProgSrc.fastSlow({
    this.aHasEp2 = true,
    this.aSourcesDelay = const Duration(milliseconds: 50),
    this.bSourcesDelay = const Duration(seconds: 5),
    this.aEpisodesDelay = Duration.zero,
  }) : aEps = const [
         Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
         Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
       ],
       bEps = const [
         Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
         Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
       ];

  final List<Episode> aEps;
  final List<Episode> bEps;

  /// When false, src-a lists only ep 1 — the pinned-failure case.
  final bool aHasEp2;

  /// Stream-fetch latency per source (the candidate-order test slows src-a
  /// below src-b; the pin-gate test speeds src-b up).
  Duration aSourcesDelay;
  final Duration bSourcesDelay;

  /// Episode-list latency for src-a (the pin-gate test slows the pinned
  /// miss above the non-pinned hit).
  final Duration aEpisodesDelay;

  /// Every episode-list and stream fetch, per source.
  final log = <String>[];
  final categories = <String>[];
  final fastFlags = <bool>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    (id: 'src-a', name: 'A'),
    (id: 'src-b', name: 'B'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  String displayName(String sourceId) => sourceId;

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async {
    log.add('search:$sourceId');
    if (sourceId == 'src-a') {
      return [
        MediaItem(
          id: 'a',
          title: 'FMA',
          url: 'https://a/show',
          type: ProviderType.anime,
          sourceId: 'src-a',
        ),
      ];
    }
    if (sourceId == 'src-b') {
      return [
        MediaItem(
          id: 'b',
          title: 'FMA',
          url: 'https://b/show',
          type: ProviderType.anime,
          sourceId: 'src-b',
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    log.add('episodes:$url:$sourceId');
    categories.add(category);
    if (sourceId == 'src-a') {
      if (aEpisodesDelay != Duration.zero) {
        await Future<void>.delayed(aEpisodesDelay);
      }
      return aHasEp2
          ? aEps
          : const [
              Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
            ];
    }
    if (sourceId == 'src-b') return bEps;
    return const [];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    log.add('sources:$episodeUrl:$sourceId');
    fastFlags.add(fast);
    if (sourceId == 'src-a') {
      await Future<void>.delayed(aSourcesDelay);
      return const [
        VideoSource(url: 'https://a/s1'),
        VideoSource(url: 'https://a/s2'),
      ];
    }
    if (sourceId == 'src-b') {
      await Future<void>.delayed(bSourcesDelay);
      return const [
        VideoSource(url: 'https://b/s1'),
        VideoSource(url: 'https://b/s2'),
        VideoSource(url: 'https://b/s3'),
      ];
    }
    return const [];
  }
}
