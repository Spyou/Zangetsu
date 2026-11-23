import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
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
