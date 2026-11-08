import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('zangetsu/phone_player');
  late Directory dir;
  late Future<bool> playback;
  late List<String> resolved;
  Map<String, dynamic>? launchArgs;

  Future<dynamic> send(String method, Map<String, dynamic> args) {
    final result = Completer<dynamic>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (data) {
        try {
          result.complete(
            data == null
                ? null
                : const StandardMethodCodec().decodeEnvelope(data),
          );
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('phone_startup');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await ResumeStore.init();
    await TitlePrefsStore.init();
    await sl.reset();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
    await sl<PlaybackPrefs>().setDefaultQuality('1080p');
    resolved = [];
    final launched = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        launchArgs = Map<String, dynamic>.from(call.arguments as Map);
        launched.complete();
      }
      return true;
    });
    playback = PhoneNativePlayer.play(
      sourceId: 'source',
      episodes: const [
        Episode(id: '1', title: 'First', url: 'https://site/sub/1', number: 1),
        Episode(id: '2', title: 'Second', url: 'https://site/sub/2', number: 2),
      ],
      startIndex: 0,
      resume: ResumeStore(),
      resolveSources: (url) async {
        resolved.add(url);
        return [
          VideoSource(
            url: 'https://high.test/video',
            quality: '1080p',
            kind: AudioKind.dub,
          ),
          VideoSource(
            url: 'https://low.test/video',
            quality: '480p',
            kind: AudioKind.dub,
          ),
        ];
      },
      category: 'dub',
      availableCategories: ['sub', 'dub'],
      showUrl: 'https://show/title',
      showTitle: 'Title',
      showDescription: 'Synopsis',
      malId: 21,
    );
    await launched.future;
  });

  tearDown(() async {
    await send('playerClosed', {'index': 0, 'positionMs': 0, 'durationMs': 0});
    await playback;
    messenger.setMockMethodCallHandler(channel, null);
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('native initial pick respects the saved quality preference', () async {
    await sl<PlaybackPrefs>().setDefaultQuality('480p');
    final payload = await send('resolveEpisode', {'index': 0}) as Map;
    expect(payload['url'], 'https://low.test/video');
    expect(resolved, ['https://site/dub/1']);
  });

  test(
    'native Simkl tracks live episode switches without first-frame history',
    () async {
      await SimklService.init();
      await Hive.box(
        SimklService.boxName,
      ).putAll({'accessToken': 'test', 'viewerName': 'tester'});
      final requests = <RequestOptions>[];
      final stopped = Completer<void>();
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              handler.resolve(
                Response(requestOptions: options, statusCode: 201),
              );
              if (options.path.endsWith('/stop') &&
                  options.data['episode']['number'] == 2) {
                stopped.complete();
              }
            },
          ),
        );
      final simkl = SimklService(dio);
      sl.registerSingleton<TrackerHub>(TrackerHub([simkl]));
      addTearDown(simkl.dispose);
      final session = launchArgs!['sessionId'];
      Future<dynamic> state(
        int index,
        int position,
        bool playing, {
        int? sessionId,
      }) => send('discordPresence', {
        'sessionId': sessionId ?? session,
        'index': index,
        'positionMs': position,
        'durationMs': 100000,
        'actualPlaying': playing,
        'playing': playing,
      });
      await state(0, 1000, true, sessionId: -1);
      await state(0, 1000, true);
      await send('playbackStarted', {'index': 0});
      await state(0, 30000, false);
      await state(0, 30000, true);
      await state(1, 1000, true);
      await send('playerClosed', {
        'sessionId': session,
        'episodeIndex': 1,
        'positionMs': 2000,
        'durationMs': 100000,
      });
      await stopped.future.timeout(const Duration(seconds: 3));
      expect(requests.map((r) => r.uri.path), [
        '/scrobble/start',
        '/scrobble/pause',
        '/scrobble/start',
        '/scrobble/stop',
        '/scrobble/start',
        '/scrobble/stop',
      ]);
      expect(requests.map((r) => r.data['episode']['number']), [
        1,
        1,
        1,
        1,
        2,
        2,
      ]);
      expect(requests.last.data['progress'], 2);
    },
  );

  test('native title quality wins over global preference', () async {
    await sl<TitlePrefsStore>().setQuality(
      'source',
      'https://show/title',
      '480p',
    );
    final payload = await send('resolveEpisode', {'index': 0}) as Map;
    expect(payload['url'], 'https://low.test/video');
  });

  test(
    'native prefetch waits until near the end and runs once for the cut',
    () async {
      await send('resolveEpisode', {'index': 0});
      await send('playbackStarted', {'index': 0});
      await send('playbackStarted', {'index': 0});
      expect(resolved, ['https://site/dub/1']);
      await send('saveProgress', {
        'index': 0,
        'positionMs': 1000,
        'durationMs': 100000,
      });
      expect(resolved, hasLength(1));
      await send('saveProgress', {
        'index': 0,
        'positionMs': 86000,
        'durationMs': 100000,
      });
      await send('saveProgress', {
        'index': 0,
        'positionMs': 90000,
        'durationMs': 100000,
      });
      expect(resolved, ['https://site/dub/1', 'https://site/dub/2']);
    },
  );

  test('a film launches with isMovie and no episode pill label', () async {
    await send('playerClosed', {'index': 0, 'positionMs': 0, 'durationMs': 0});
    await playback;
    final relaunch = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        launchArgs = Map<String, dynamic>.from(call.arguments as Map);
        relaunch.complete();
      }
      return true;
    });
    final relaunched = PhoneNativePlayer.play(
      sourceId: 'source',
      episodes: const [
        Episode(
          id: '1',
          title: 'Episode 1',
          number: 1,
          url: 'https://site/sub/1',
        ),
      ],
      startIndex: 0,
      resume: ResumeStore(),
      resolveSources: (url) async => const [],
      showTitle: 'Film',
      isMovie: true,
    );
    await relaunch.future;
    expect(launchArgs?['isMovie'], isTrue);
    expect(launchArgs?['episodeLabel'], 'Film');
    await send('playerClosed', {'index': 0, 'positionMs': 0, 'durationMs': 0});
    await relaunched;
  });
}
