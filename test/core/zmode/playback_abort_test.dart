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
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

const _ep2 = 'zm://anime/mal:100/ep/2';

/// Two sources. `slow` never answers its episode call, standing in for the real
/// thing the freeze was made of: a JS provider holding the shared provider
/// queue — and the UI isolate with it — until its own timeout.
class _Src implements SourceRepository {
  _Src({this.slow = const <String>{}});

  final Set<String> slow;
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
    return [
      MediaItem(
        id: sourceId ?? '',
        title: 'FMA',
        url: 'https://${sourceId ?? ""}/show',
        type: ProviderType.anime,
        sourceId: sourceId ?? '',
      ),
    ];
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    log.add('episodes:$sourceId');
    if (slow.contains(sourceId)) return Completer<List<Episode>>().future;
    return [
      Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://$sourceId/1'),
      Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://$sourceId/2'),
    ];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    log.add('sources:$sourceId');
    return [VideoSource(url: 'https://$sourceId/stream')];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('playback-abort');
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

  ({PlaybackResolver resolver, _Src src}) build({Set<String> slow = const {}}) {
    final src = _Src(slow: slow);
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
      // Short so the hung first candidate gives the loop back quickly; the
      // real one is 8s.
      perSourceBudget: const Duration(milliseconds: 120),
    );
    r.bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
    return (resolver: r, src: src);
  }

  test('leaving mid-sweep stops it before the next source is asked', () async {
    final b = build(slow: {'src-a'});
    final f = b.resolver.resolveForPlayback(_ep2);
    b.resolver.abortSweeps(); // the viewer pressed back

    await expectLater(f, throwsA(isA<PlaybackAborted>()));
    expect(
      b.src.log.where((l) => l.endsWith('src-b')),
      isEmpty,
      reason: 'src-b was asked anyway — the sweep did not stop',
    );
  });

  test('an abandoned sweep is not remembered as "nothing has this"', () async {
    // The trap: the miss cache is what makes a failed sweep instant next time.
    // A sweep that stopped after one of two candidates never asked the rest,
    // so recording it would make the next tap fail instantly for the whole
    // cooldown — on sources that were never tried.
    final b = build(slow: {'src-a'});
    final f = b.resolver.resolveForPlayback(_ep2);
    b.resolver.abortSweeps();
    await expectLater(f, throwsA(isA<PlaybackAborted>()));

    // Tapping again sweeps properly and finds B.
    final again = await b.resolver.resolveForPlayback(_ep2);
    expect(again.match.sourceId, 'src-b');
  });

  test('a download sweep is not cancelled by the player closing', () async {
    // Downloads walk the same loop via `accept`, but nobody is waiting on a
    // screen — closing the player must not kill one.
    final b = build(slow: {'src-a'});
    final f = b.resolver.resolveForPlayback(
      _ep2,
      accept: (streams) => streams.isNotEmpty,
    );
    b.resolver.abortSweeps();

    final resolved = await f;
    expect(resolved.match.sourceId, 'src-b');
  });

  test('a sweep started after the abort runs normally', () async {
    final b = build();
    b.resolver.abortSweeps(); // an earlier player closed
    final resolved = await b.resolver.resolveForPlayback(_ep2);
    expect(resolved.match.sourceId, 'src-a');
  });

  test('nothing changes when the viewer stays', () async {
    final b = build();
    final resolved = await b.resolver.resolveForPlayback(_ep2);
    expect(resolved.match.sourceId, 'src-a');
    expect(resolved.streams.single.url, 'https://src-a/stream');
  });
}
