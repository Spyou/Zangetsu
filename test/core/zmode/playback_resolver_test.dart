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
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

const _show = ZCanonical(ZKind.anime, 'mal:100');
const _ep2 = 'zm://anime/mal:100/ep/2';

class _SweepSrc implements SourceRepository {
  _SweepSrc({
    required this.aEps,
    required this.bEps,
    this.aStreams = const [VideoSource(url: 'https://a/stream')],
    this.bStreams = const [VideoSource(url: 'https://b/stream')],
  });

  final List<Episode> aEps;
  final List<Episode> bEps;
  final List<VideoSource> aStreams;
  final List<VideoSource> bStreams;
  final log = <String>[];

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
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async {
    log.add('search:$sourceId');
    if (sourceId == 'src-a') {
      return [MediaItem(id: 'a', title: 'FMA', url: 'https://a/show', type: ProviderType.anime, sourceId: 'src-a')];
    }
    if (sourceId == 'src-b') {
      return [MediaItem(id: 'b', title: 'FMA', url: 'https://b/show', type: ProviderType.anime, sourceId: 'src-b')];
    }
    return const [];
  }

  @override
  Future<List<Episode>> episodes(String url, {String category = 'sub', String? sourceId}) async {
    log.add('episodes:$url:$sourceId');
    if (sourceId == 'src-a') return aEps;
    if (sourceId == 'src-b') return bEps;
    return const [];
  }

  @override
  Future<List<VideoSource>> sources(String episodeUrl, {String? sourceId, bool fast = false}) async {
    log.add('sources:$episodeUrl:$sourceId');
    if (sourceId == 'src-a') return aStreams;
    if (sourceId == 'src-b') return bStreams;
    return const [];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('playback-resolver');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  PlaybackResolver resolver({
    required SourceRepository sources,
    required SourceMatcher matcher,
    String? preferred,
  }) {
    if (preferred != null) prefs.set(_show.kind, preferred);
    final r = PlaybackResolver(
      matcher: matcher,
      sources: sources,
      store: store,
      prefs: prefs,
      health: health,
      candidates: (_) => [(id: 'src-a', name: 'A'), (id: 'src-b', name: 'B')],
    );
    r.bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
    return r;
  }

  test('tries second source when first lacks the episode', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');
    final out = await r.resolveForPlayback(_ep2);
    expect(out.match.sourceId, 'src-b');
    expect(out.episodeUrl, 'https://b/2');
    expect(src.log, contains('sources:https://b/2:src-b'));
  });

  test('prefers pinned source over preferred', () async {
    await store.pin(_show, const SourceMatch(
      sourceId: 'src-a',
      showUrl: 'https://a/show',
      showId: 'a',
      showTitle: 'FMA',
      pinned: true,
    ));
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    prefs.set(_show.kind, 'src-b');
    final r = resolver(sources: src, matcher: matcher);
    final out = await r.resolveForPlayback(_ep2);
    expect(out.match.sourceId, 'src-a');
  });

  test('throws EpisodeNotAvailable when episode missing everywhere', () async {
    final src = _SweepSrc(
      aEps: const [Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1')],
      bEps: const [Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1')],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher);
    expect(
      () => r.resolveForPlayback('zm://anime/mal:100/ep/5'),
      throwsA(isA<EpisodeNotAvailable>().having((e) => e.hadTitleMatch, 'hadTitleMatch', isTrue)),
    );
  });

  test('dedupes in-flight resolves for the same episode url', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');
    final a = r.resolveForPlayback(_ep2);
    final b = r.resolveForPlayback(_ep2);
    expect(identical(await a, await b), isTrue);
  });
}
