import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('phone_player_selection');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('built-in MPV remains the default selection', () async {
    await PlaybackPrefs.init();
    expect(PlaybackPrefs().externalPlayerPackage, '');
    expect(PlaybackPrefs.androidPlayerId, isNotEmpty);
  });

  test('legacy experimental selection migrates to Android Player', () async {
    final box = await Hive.openBox<dynamic>(PlaybackPrefs.boxName);
    await box.put('experimentalExoPlayer', true);

    await PlaybackPrefs.init();

    expect(
      PlaybackPrefs().externalPlayerPackage,
      PlaybackPrefs.androidPlayerId,
    );
    expect(box.get('experimentalExoPlayer'), isNull);
  });
}
