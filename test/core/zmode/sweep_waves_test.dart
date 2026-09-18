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

const _ep2 = 'zm://anime/mal:100/ep/2';

/// Sources that each take [delay] to answer, and only those in [hasEpisode2]
/// can actually serve the episode.
///
/// The delays are what the wave tests measure: run one at a time, three 200ms
/// sources cost 600ms; run together they cost 200ms.
class _TimedSrc implements SourceRepository {
  _TimedSrc({
    required this.ids,
    required this.delay,
    required this.hasEpisode2,
  });

  final List<String> ids;
  final Map<String, Duration> delay;
  final Set<String> hasEpisode2;

  /// The order episode lists were actually requested in.
  final asked = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources =>
      [for (final id in ids) (id: id, name: id)];

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
    asked.add(sourceId!);
    await Future<void>.delayed(delay[sourceId] ?? Duration.zero);
    return [
      Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://$sourceId/1'),
      if (hasEpisode2.contains(sourceId))
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://$sourceId/2'),
    ];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async => [VideoSource(url: 'https://$sourceId/stream')];
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sweep-waves');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    JsEngine.debugRunsOffUiIsolateOverride = true;
  });

  tearDown(() async {
    JsEngine.debugRunsOffUiIsolateOverride = null;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  PlaybackResolver build(_TimedSrc src) {
    final r = PlaybackResolver(
      matcher: SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => src.loadedSources,
      ),
      sources: src,
      store: store,
      prefs: prefs,
      health: health,
      candidates: (_) => src.loadedSources,
      perSourceBudget: const Duration(seconds: 5),
    );
    r.bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
    return r;
  }

  // The whole point. Three sources that each take 200ms cost 600ms when asked
  // one at a time and about 200ms when asked together — that difference IS the
  // feature, so it is measured rather than assumed.
  test('a wave asks its sources at the same time, not one after another',
      () async {
    final src = _TimedSrc(
      ids: const ['a', 'b', 'c'],
      delay: const {
        'a': Duration(milliseconds: 200),
        'b': Duration(milliseconds: 200),
        'c': Duration(milliseconds: 200),
      },
      // Only the last one can serve it, so all three are asked.
      hasEpisode2: const {'c'},
    );
    final sw = Stopwatch()..start();
    final out = await build(src).sources(_ep2);
    sw.stop();

    expect(out, isNotEmpty);
    expect(src.asked.length, 3, reason: 'all three were needed');
    expect(
      sw.elapsedMilliseconds,
      lessThan(450),
      reason: 'one at a time would be ~600ms; together it is ~200ms',
    );
  });

  // Order is the viewer's own priority. Whichever source happens to answer
  // first must NOT win, or the ranking they set is quietly replaced by a race.
  test('when two in a wave can serve it, the earlier candidate wins', () async {
    final src = _TimedSrc(
      ids: const ['a', 'b', 'c'],
      delay: const {
        // 'a' is first in the list but slowest to answer.
        'a': Duration(milliseconds: 150),
        'b': Duration(milliseconds: 10),
        'c': Duration(milliseconds: 10),
      },
      hasEpisode2: const {'a', 'b', 'c'},
    );
    final out = await build(src).sources(_ep2);
    expect(
      out.first.url,
      contains('a/'),
      reason: 'candidate order beats completion order',
    );
  });

  // A source that blows up must not take its wave-mates down with it — the
  // try/catch is per candidate, and staying that way is what this pins.
  test('one source failing does not lose the others in its wave', () async {
    final src = _ThrowingFirst(
      ids: const ['boom', 'b', 'c'],
      delay: const {},
      hasEpisode2: const {'c'},
    );
    final out = await build(src).sources(_ep2);
    expect(out, isNotEmpty, reason: 'c still answered');
  });

  // More candidates than one wave holds: it must keep going rather than give
  // up at the end of the first three.
  test('the sweep continues into later waves', () async {
    final src = _TimedSrc(
      ids: const ['a', 'b', 'c', 'd', 'e'],
      delay: const {},
      // Only the 5th — reachable only if a second wave runs.
      hasEpisode2: const {'e'},
    );
    final out = await build(src).sources(_ep2);
    expect(out, isNotEmpty);
    expect(src.asked, containsAll(<String>['a', 'e']));
  });
}

/// Same as [_TimedSrc] but the first source throws instead of answering.
class _ThrowingFirst extends _TimedSrc {
  _ThrowingFirst({
    required super.ids,
    required super.delay,
    required super.hasEpisode2,
  });

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    asked.add(sourceId!);
    if (sourceId == 'boom') throw StateError('provider exploded');
    return super.episodes(url, category: category, sourceId: sourceId);
  }
}
