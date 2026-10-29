import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';

class _Presence extends DiscordRpc {
  _Presence() : super(Dio());
  final updates =
      <({String title, String? episode, bool playing, Duration position})>[];
  int clears = 0;
  @override
  Future<void> setWatching({
    required String title,
    String? episodeLabel,
    String? posterUrl,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool playing = true,
    String? openUrl,
  }) async {
    updates.add((
      title: title,
      episode: episodeLabel,
      playing: playing,
      position: position,
    ));
  }

  @override
  void clear({Duration delay = Duration.zero}) {
    clears++;
  }
}

class _Resume extends ResumeStore {
  int saves = 0;
  @override
  Future<void> save(
    String sourceId,
    String showId,
    String episodeId,
    Duration position,
    Duration duration,
  ) async {
    saves++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('zangetsu/phone_player');
  late Directory dir;
  late _Presence presence;
  late Completer<void> launched;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('phone_presence');
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    await sl.reset();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    presence = _Presence();
    sl.registerSingleton<DiscordRpc>(presence);
    launched = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (_) async {
      launched.complete();
      return true;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });
  Future<void> send(String method, Map<String, Object> args) async {
    final replied = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => replied.complete(),
    );
    await replied.future;
  }

  Future<bool> open(_Resume resume, {bool peek = false}) =>
      PhoneNativePlayer.play(
        sourceId: 'test',
        episodes: const [
          Episode(id: '1', title: 'Episode 1', url: 'ep1', number: 1),
          Episode(id: '2', title: 'Episode 2', url: 'ep2', number: 2),
        ],
        startIndex: 0,
        resume: resume,
        resolveSources: (_) async => [],
        showTitle: 'Series',
        showUrl: 'series',
        peek: peek,
      );
  test(
    'native play, pause, episode change, seek and exit update presence',
    () async {
      final resume = _Resume();
      final playback = open(resume);
      await launched.future;
      await Future<void>.delayed(Duration.zero);
      await send('discordPresence', {
        'index': 0,
        'positionMs': 1000,
        'durationMs': 60000,
        'playing': true,
      });
      expect(presence.updates.single.title, 'Series');
      expect(presence.updates.single.playing, isTrue);
      await send('discordPresence', {
        'index': 99,
        'positionMs': 1000,
        'durationMs': 60000,
        'playing': true,
      });
      await send('discordPresence', {
        'index': 0,
        'positionMs': 1000,
        'durationMs': 0,
        'playing': true,
      });
      expect(presence.updates.length, 1);

      await send('discordPresence', {
        'index': 0,
        'positionMs': 2000,
        'durationMs': 60000,
        'playing': false,
      });
      expect(presence.updates.last.playing, isFalse);
      await send('discordPresence', {
        'index': 1,
        'positionMs': 25000,
        'durationMs': 60000,
        'playing': true,
      });
      expect(presence.updates.last.episode, 'Episode 2');
      expect(presence.updates.last.position.inSeconds, 25);
      expect(
        resume.saves,
        0,
        reason: 'Presence events must not write progress',
      );
      await send('playerClosed', {
        'index': 1,
        'positionMs': 25000,
        'durationMs': 60000,
      });
      expect(await playback, isTrue);
      expect(presence.clears, 1);
      expect(resume.saves, 1);
      await send('discordPresence', {
        'index': 0,
        'positionMs': 0,
        'durationMs': 60000,
        'playing': true,
      });
      expect(
        presence.updates.length,
        3,
        reason: 'Late events cannot resurrect Watching',
      );
    },
  );
  test('preview and invalid progress do not publish activity', () async {
    final playback = open(_Resume(), peek: true);
    await launched.future;
    await Future<void>.delayed(Duration.zero);
    await send('discordPresence', {
      'index': 0,
      'positionMs': 1,
      'durationMs': 60000,
      'playing': true,
    });
    expect(presence.updates, isEmpty);
    await send('playerClosed', {'index': 0, 'positionMs': 0, 'durationMs': 0});
    await playback;
    expect(presence.clears, 0);
  });
}
