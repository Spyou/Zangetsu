import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('phone_cache_test');
    Hive.init(directory.path);
    await Hive.openBox<dynamic>(PlaybackPrefs.boxName);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'extra caches default off and remain separate from existing presets',
    () async {
      final prefs = PlaybackPrefs();
      expect(prefs.phoneNativeCacheEnabled, isFalse);
      expect(prefs.phoneDiskCacheEnabled, isFalse);
      expect(prefs.phoneNativeCacheMb, 128);
      expect(prefs.phoneDiskCacheGb, 2);
      await prefs.setPhoneNativeCacheEnabled(true);
      await prefs.setPhoneDiskCacheEnabled(true);
      await prefs.setPhoneNativeCacheMb(256);
      await prefs.setPhoneDiskCacheGb(4);
      final restored = PlaybackPrefs();
      expect(restored.phoneNativeCacheEnabled, isTrue);
      expect(restored.phoneDiskCacheEnabled, isTrue);
      expect(restored.phoneNativeCacheMb, 256);
      expect(restored.phoneDiskCacheGb, 4);
      expect(restored.videoBufferSize, 'default');
      expect(restored.videoBufferLength, 'default');
    },
  );

  test('cache amounts reject unsafe stored and input values', () async {
    final prefs = PlaybackPrefs();
    await prefs.setPhoneNativeCacheMb(1000000);
    await prefs.setPhoneDiskCacheGb(-1);
    expect(prefs.phoneNativeCacheMb, 512);
    expect(prefs.phoneDiskCacheGb, 1);
    await Hive.box<dynamic>(
      PlaybackPrefs.boxName,
    ).put('phoneNativeCacheMb', 'bad');
    await Hive.box<dynamic>(PlaybackPrefs.boxName).put('phoneDiskCacheGb', 99);
    expect(prefs.phoneNativeCacheMb, 128);
    expect(prefs.phoneDiskCacheGb, 20);
  });
}
