import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/title_prefs.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('title_prefs_binge_test');
    Hive.init(tempDir.path);
    await TitlePrefsStore.init();
  });

  tearDown(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('remembered binge group is returned per show', () async {
    final store = TitlePrefsStore();
    expect(store.stremioBingeGroup('show-1'), isNull);

    await store.rememberStremioBingeGroup('show-1', 'bluray-1080p');
    expect(store.stremioBingeGroup('show-1'), 'bluray-1080p');

    // Other shows are unaffected.
    expect(store.stremioBingeGroup('show-2'), isNull);

    // Empty groups never overwrite a remembered one.
    await store.rememberStremioBingeGroup('show-1', null);
    await store.rememberStremioBingeGroup('show-1', '');
    expect(store.stremioBingeGroup('show-1'), 'bluray-1080p');
  });
}
