import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/features/player/tv_native_player.dart';

const _old = VideoSource(url: 'https://host/a', label: 'A');
const _stale = VideoSource(url: 'https://host/b', label: 'B-old');
const _freshB = VideoSource(url: 'https://host/b', label: 'B-new');
const _freshC = VideoSource(url: 'https://host/c', label: 'C');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zangetsu/tv_player');
  late Directory directory;
  late Completer<Map<String, dynamic>> closed;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tv-refresh-test');
    Hive.init(directory.path);
    await PlaybackPrefs.init();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    closed = Completer();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      if (call.method == 'launch') return closed.future;
      return Future.value();
    });
  });

  tearDown(() async {
    if (!closed.isCompleted) closed.complete({'launched': true});
    await Future<void>.delayed(Duration.zero);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    TvNativePlayer.refreshTimeout = const Duration(seconds: 15);
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  /// Opens a TV session and leaves the player "on screen" until tearDown.
  Future<Future<bool>> open({
    String showUrl = 'https://show',
    String category = 'sub',
    Future<List<VideoSource>> Function(String url)? poll,
    Future<List<VideoSource>> Function(String url)? resolve,
  }) async {
    final play = TvNativePlayer.play(
      sourceId: 'fourkhdhub',
      episodes: const [
        Episode(id: '1', title: 'Episode 1', url: 'zm://anime/mal:1/ep/1'),
        Episode(id: '2', title: 'Episode 2', url: 'zm://anime/mal:1/ep/2'),
      ],
      startIndex: 0,
      resume: _UnusedResumeStore(),
      resolveSources: resolve ?? (_) async => const [_old, _stale],
      pollSources: poll,
      showUrl: showUrl,
      category: category,
    );
    await Future<void>.delayed(Duration.zero);
    return play;
  }

  Future<List<String>> labels(Map<String, dynamic> args) async {
    final out = await TvNativePlayer.debugHandleNativeCall(
      MethodCall('sourcesFor', args),
    );
    return [for (final m in out as List) (m as Map)['label'] as String];
  }

  test('mergeSourcesByUrl keeps order, refreshes known urls, appends new', () {
    expect(
      TvNativePlayer.mergeSourcesByUrl(
        const [_old, _stale],
        const [_freshB, _freshC],
      ).map((s) => s.label),
      ['A', 'B-new', 'C'],
    );
  });

  test(
    'refresh:true runs a full (non-fast) catalogue resolve and merges it',
    () async {
      final catalogue = _FakeCatalogue(fresh: const [_freshB, _freshC]);
      sl.registerSingleton<CatalogueRepository>(catalogue);
      await open(poll: (_) async => const []);

      expect(await labels({'index': 0, 'category': 'sub', 'refresh': true}), [
        'A',
        'B-new',
        'C',
      ]);
      expect(catalogue.fastFlags, [false]);
      // The fresh mirrors stay in the picker afterwards.
      expect(await labels({'index': 0, 'category': 'sub'}), [
        'A',
        'B-new',
        'C',
      ]);
      expect(catalogue.fastFlags, [false]);
    },
  );

  test('without refresh no fresh resolve runs', () async {
    final catalogue = _FakeCatalogue(fresh: const [_freshC]);
    sl.registerSingleton<CatalogueRepository>(catalogue);
    await open(poll: (_) async => const []);

    expect(await labels({'index': 0, 'category': 'sub'}), ['A', 'B-old']);
    expect(catalogue.fastFlags, isEmpty);
  });

  test('a refresh that times out returns the mirrors already known', () async {
    TvNativePlayer.refreshTimeout = const Duration(milliseconds: 20);
    final catalogue = _FakeCatalogue(fresh: const [_freshC], hang: true);
    sl.registerSingleton<CatalogueRepository>(catalogue);
    await open(poll: (_) async => const []);

    expect(await labels({'index': 0, 'category': 'sub', 'refresh': true}), [
      'A',
      'B-old',
    ]);
  });

  test(
    'without a progressive lookup the poll snapshot is read first',
    () async {
      final catalogue = _FakeCatalogue(
        fresh: const [],
        snapshot: const [_freshC],
      );
      sl.registerSingleton<CatalogueRepository>(catalogue);
      var resolves = 0;
      await open(
        resolve: (_) async {
          resolves++;
          return const [_old];
        },
      );

      expect(await labels({'index': 0, 'category': 'sub'}), ['C']);
      expect(resolves, 0);
    },
  );

  test(
    'a playback error excludes the dub source and records no health strike',
    () async {
      final resolver = _FakeResolver();
      final health = _FakeHealth();
      sl.registerSingleton<PlaybackResolver>(resolver);
      sl.registerSingleton<SourceHealthStore>(health);
      await open(showUrl: 'zm://anime/mal:1', category: 'dub');

      await TvNativePlayer.debugHandleNativeCall(
        const MethodCall('playbackError', {
          'errorCode': 'ERROR_CODE_DECODING_FAILED',
          'index': 1,
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(TvNativePlayer.lastPlaybackErrorIndex, 1);
      expect(resolver.askedCategories, ['dub']);
      expect(resolver.unplayable, ['fourkhdhub-dub|dub']);
      expect(health.records, isEmpty);
    },
  );
}

class _FakeCatalogue implements CatalogueRepository {
  _FakeCatalogue({
    required this.fresh,
    this.snapshot = const [],
    this.hang = false,
  });

  final List<VideoSource> fresh;
  final List<VideoSource> snapshot;
  final bool hang;
  final fastFlags = <bool>[];

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) {
    fastFlags.add(fast);
    if (hang) return Completer<List<VideoSource>>().future;
    return Future.value(fresh);
  }

  @override
  Future<({List<VideoSource> sources, bool done})> polledSources(
    String episodeUrl, {
    String? sourceId,
  }) async => (sources: snapshot, done: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResolver implements PlaybackResolver {
  final askedCategories = <String>[];
  final unplayable = <String>[];

  @override
  String? resolvedSourceId(String zmEpisodeUrl, {String category = 'sub'}) {
    askedCategories.add(category);
    return category == 'dub' ? 'fourkhdhub-dub' : 'fourkhdhub-sub';
  }

  @override
  void markSourceUnplayable(
    String zmEpisodeUrl,
    String sourceId, {
    String category = 'sub',
  }) => unplayable.add('$sourceId|$category');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHealth implements SourceHealthStore {
  final records = <String>[];

  @override
  Future<void> record(
    String id,
    SourceOutcome outcome, {
    int? responseMs,
  }) async => records.add('$id:$outcome');

  @override
  Future<void> recordPlayback(
    String id,
    String titleKey, {
    required bool ok,
  }) async => records.add('$id:playback:$ok');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedResumeStore implements ResumeStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
