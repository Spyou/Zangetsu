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
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';
import 'package:watch_app/features/player/player_engine_fallback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('zangetsu/phone_player');
  const source = VideoSource(
    url: 'https://cdn.test/high',
    quality: '1080p',
    headers: {'Referer': 'https://site.test'},
    subtitles: [Subtitle(url: 'https://sub.test/en.srt', lang: 'en')],
  );
  const second = VideoSource(url: 'https://cdn.test/low', quality: '480p');
  late Directory dir;
  late PlayerEngineFallback fallback;
  late Future<bool> playback;
  late Map<String, dynamic> launch;
  PhonePlaybackFailure? failure;

  Future<dynamic> send(String method, Map<String, dynamic> args) async {
    final done = Completer<dynamic>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (data) => done.complete(
        data == null ? null : const StandardMethodCodec().decodeEnvelope(data),
      ),
    );
    return done.future;
  }

  Future<void> close({bool recovery = false, String? url}) async {
    await send('playerClosed', {
      'sessionId': launch['sessionId'],
      'episodeIndex': 0,
      'positionMs': 42000,
      'durationMs': 100000,
      'engineFallback': recovery,
      'url': url ?? source.url,
    });
    await playback;
  }

  Future<void> start({
    bool enabled = true,
    VideoSource? seed,
    bool forceResume = false,
    Future<List<VideoSource>> Function(String)? resolve,
  }) async {
    await sl<PlaybackPrefs>().setAutoPlayerFallback(enabled);
    final opened = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        launch = Map<String, dynamic>.from(call.arguments as Map);
        opened.complete();
      }
      return true;
    });
    playback = PhoneNativePlayer.play(
      sourceId: 'source',
      episodes: const [
        Episode(id: '1', title: 'First', url: 'episode-1', number: 1),
      ],
      startIndex: 0,
      resume: ResumeStore(),
      category: 'dub',
      resolveSources: resolve ?? (_) async => [source, second],
      initialSource: seed,
      showDescription: 'Description',
      engineFallback: fallback,
      onEngineFallback: (value) => failure = value,
      resumePosition: 42000,
      forceInitialResume: forceResume,
    );
    await opened.future;
  }

  Future<dynamic> request({int? session, String? url, int index = 0}) =>
      send('tryOtherPlayer', {
        'sessionId': session ?? launch['sessionId'],
        'index': index,
        'url': url ?? source.url,
        'positionMs': 42000,
      });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('engine_fallback');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await ResumeStore.init();
    await TitlePrefsStore.init();
    await sl.reset();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
    fallback = PlayerEngineFallback();
    failure = null;
  });
  tearDown(() async {
    await close();
    messenger.setMockMethodCallHandler(channel, null);
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('off keeps the existing launch and source list', () async {
    await start(enabled: false);
    expect(launch['autoPlayerFallback'], isNull);
    await send('resolveEpisode', {'index': 0});
    expect(await request(), isFalse);
    expect((await send('sourcesFor', {'index': 0}) as List).length, 2);
    expect(failure, isNull);
  });

  test(
    'confirmed handoff retains episode, headers, subtitles and position',
    () async {
      await start();
      expect(launch['autoPlayerFallback'], isTrue);
      await send('resolveEpisode', {'index': 0});
      expect(await request(), isTrue);
      expect(failure, isNull);
      await close(recovery: true);
      expect(failure!.source, same(source));
      expect(failure!.source.headers, source.headers);
      expect(failure!.source.subtitles, source.subtitles);
      expect(failure!.episodes.single.id, '1');
      expect(failure!.index, 0);
      expect(failure!.category, 'dub');
      expect(failure!.position, const Duration(seconds: 42));
    },
  );

  test('a normal close does not execute a cancelled handoff', () async {
    await start();
    await send('resolveEpisode', {'index': 0});
    expect(await request(), isTrue);
    await close();
    expect(failure, isNull);
  });

  test(
    'stale sessions, unknown URLs and invalid episodes cannot switch',
    () async {
      await start();
      await send('resolveEpisode', {'index': 0});
      expect(await request(session: -1), isFalse);
      expect(await request(url: 'https://unknown.test'), isFalse);
      expect(await request(index: 1), isFalse);
      expect(failure, isNull);
    },
  );

  test(
    'after both engines fail, existing mirror fallback gets the next link',
    () async {
      await start();
      fallback.next(
        enabled: true,
        failedEngine: PlaybackEngine.mpv,
        episodeUrl: 'episode-1',
        category: 'dub',
        source: source,
      );
      await send('resolveEpisode', {'index': 0});
      expect(await request(), isFalse);
      final mirrors = await send('sourcesFor', {'index': 0}) as List;
      expect(mirrors.map((e) => (e as Map)['url']), [second.url]);
      expect(await request(url: second.url), isTrue);
    },
  );

  test(
    'a closed session cannot replace a new session fallback links',
    () async {
      final late = Completer<List<VideoSource>>();
      await start(resolve: (_) => late.future);
      final oldReply = send('resolveEpisode', {'index': 0});
      await Future<void>.delayed(Duration.zero);
      await close();
      await start();
      await send('resolveEpisode', {'index': 0});
      const oldSource = VideoSource(url: 'https://old-session.test/video');
      late.complete([oldSource]);
      expect(await oldReply, isNull);
      expect(await request(url: oldSource.url), isFalse);
      expect(await request(), isTrue);
    },
  );

  test('DRM stays in the native player', () async {
    const drm = VideoSource(
      url: 'https://cdn.test/drm',
      drmKid: 'id',
      drmKey: 'key',
    );
    await start(seed: drm);
    await send('resolveEpisode', {'index': 0});
    expect(await request(url: drm.url), isFalse);
  });

  test(
    'recovery position survives auto-resume being off without changing it',
    () async {
      await sl<PlaybackPrefs>().setAutoResume(false);
      await start(seed: source, forceResume: true);
      expect(
        (await send('resolveEpisode', {'index': 0}) as Map)['positionMs'],
        42000,
      );
      expect(sl<PlaybackPrefs>().autoResume, isFalse);
      expect(
        (await send('resolveEpisode', {'index': 0}) as Map)['positionMs'],
        0,
      );
    },
  );
}
