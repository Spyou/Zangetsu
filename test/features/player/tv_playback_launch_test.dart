import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/features/player/tv_native_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/tv_playback_launch.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('native TV opens before the first episode source lookup', () async {
    final directory = await Directory.systemTemp.createTemp('tv-opening-test');
    Hive.init(directory.path);
    await PlaybackPrefs.init();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    const channel = MethodChannel('zangetsu/tv_player');
    final messenger = binding.defaultBinaryMessenger;
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await sl.reset();
      await Hive.close();
      await directory.delete(recursive: true);
    });

    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'launch');
      expect(call.arguments, containsPair('resolveOnOpen', true));
      expect(call.arguments, isNot(contains('url')));
      return {'launched': true};
    });

    expect(
      await TvNativePlayer.play(
        sourceId: 'test',
        episodes: const [Episode(id: '1', title: 'Episode 1', url: 'ep1')],
        startIndex: 0,
        resume: _UnusedResumeStore(),
        resolveSources: (_) => throw StateError('Look up sources after launch'),
      ),
      isTrue,
    );
  });

  group('native TV playback error recovery', () {
    late Directory directory;
    late _FakeResolver resolver;
    const channel = MethodChannel('zangetsu/tv_player');
    final episodes = [
      for (var i = 1; i <= 5; i++)
        Episode(id: '$i', title: 'Episode $i', url: 'zm://anime/mal:1/ep/$i'),
    ];

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('tv-recovery-test');
      Hive.init(directory.path);
      await PlaybackPrefs.init();
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<SourceRepository>(_FakeSources());
      resolver = _FakeResolver();
      sl.registerSingleton<PlaybackResolver>(resolver);
    });

    tearDown(() async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await sl.reset();
      await Hive.close();
      await directory.delete(recursive: true);
    });

    /// The first launch fails on [failAt]; later launches play.
    List<int> fakeNative({required int failAt}) {
      final launches = <int>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method != 'launch') return null;
        launches.add((call.arguments as Map)['startIndex'] as int);
        if (launches.length > 1) return {'launched': true};
        await TvNativePlayer.debugHandleNativeCall(
          MethodCall('playbackError', {
            'errorCode': 'ERROR_CODE_DECODING_FAILED',
            'index': failAt,
          }),
        );
        return {'launched': true, 'playbackError': true};
      });
      return launches;
    }

    Future<({Future<void> done})> start(
      WidgetTester tester, {
      int sourceHop = 0,
    }) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final done = launchTvPlayback(
        context: context,
        sourceId: 'zm',
        episodes: episodes,
        startIndex: 0,
        resume: _UnusedResumeStore(),
        resolveSources: (_) async => const <VideoSource>[],
        showUrl: 'zm://anime/mal:1',
        sourceHop: sourceHop,
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      return (done: done);
    }

    testWidgets('auto-hop replays the episode that failed', (tester) async {
      final launches = fakeNative(failAt: 3);
      await (await start(tester)).done;
      expect(launches, [0, 3]);
      // Only the first, fresh play forgets what the resolver learned.
      expect(resolver.invalidated, ['zm://anime/mal:1/ep/1']);
      expect(resolver.unplayable, ['zm://anime/mal:1/ep/4']);
    });

    testWidgets('Try Next Source keeps the hop count and the failed episode', (
      tester,
    ) async {
      final launches = fakeNative(failAt: 2);
      final (:done) = await start(tester, sourceHop: kMaxTvSourceHops);
      expect(find.text('Try Next Source'), findsOneWidget);
      await tester.tap(find.text('Try Next Source'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await done;
      expect(launches, [0, 2]);
      // invalidateWinner would wipe the unplayable set and hand back the same
      // dead source.
      expect(resolver.invalidated, isEmpty);
    });
  });

  group('tvPlayerKind', () {
    test('Apple TV always uses system AVKit', () {
      expect(
        tvPlayerKind(appleTv: true, nativeTvPlayer: false),
        TvPlayerKind.avPlayerSystem,
      );
      expect(
        tvPlayerKind(appleTv: true, nativeTvPlayer: true),
        TvPlayerKind.avPlayerSystem,
      );
    });

    test('Android TV respects native Exo vs platform view', () {
      expect(
        tvPlayerKind(appleTv: false, nativeTvPlayer: true),
        TvPlayerKind.nativeExo,
      );
      expect(
        tvPlayerKind(appleTv: false, nativeTvPlayer: false),
        TvPlayerKind.exoView,
      );
    });
  });
}

class _UnusedResumeStore implements ResumeStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSources implements SourceRepository {
  @override
  List<({String id, String name})> get pickableSources => const [
    (id: 'fourkhdhub', name: '4KHDHub'),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResolver implements PlaybackResolver {
  final invalidated = <String>[];
  final unplayable = <String>[];

  @override
  void invalidateWinner(String zmEpisodeUrl) => invalidated.add(zmEpisodeUrl);

  @override
  String? resolvedSourceId(String zmEpisodeUrl, {String category = 'sub'}) =>
      'fourkhdhub';

  @override
  void markSourceUnplayable(
    String zmEpisodeUrl,
    String sourceId, {
    String category = 'sub',
  }) => unplayable.add(zmEpisodeUrl);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
