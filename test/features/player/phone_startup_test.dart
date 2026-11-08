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
