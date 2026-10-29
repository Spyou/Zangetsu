import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('player_orientation');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('player orientation defaults to landscape', () async {
    await PlaybackPrefs.init();
    expect(PlaybackPrefs().playerOrientation, 'landscape');
  });

  test('player orientation round-trips', () async {
    await PlaybackPrefs.init();
    final p = PlaybackPrefs();
    await p.setPlayerOrientation('portrait');
    expect(PlaybackPrefs().playerOrientation, 'portrait');
    await p.setPlayerOrientation('system');
    expect(PlaybackPrefs().playerOrientation, 'system');
  });

  test('orientation lock mapping', () {
    expect(
      PlaybackPrefs.orientationLockFor('landscape'),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
    expect(
      PlaybackPrefs.orientationLockFor('portrait'),
      const [DeviceOrientation.portraitUp],
    );
    expect(
      PlaybackPrefs.orientationLockFor('system'),
      DeviceOrientation.values,
    );
    // Unknown values fall back to today's behaviour, not portrait.
    expect(
      PlaybackPrefs.orientationLockFor('bogus'),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
  });
}
