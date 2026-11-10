import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('title_prefs_sub_test');
    Hive.init(tempDir.path);
    await TitlePrefsStore.init();
  });

  tearDown(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('native language codes remain usable by every player', () async {
    final store = TitlePrefsStore();
    await store.setSubtitleChoice('stremio', 'show', 'eng');
    expect(store.subtitleChoice('stremio', 'show'), 'en');
    await store.setSubtitleChoice('stremio', 'show', 'pt-BR');
    expect(store.subtitleChoice('stremio', 'show'), 'pt');
    await store.setSubtitleChoice('stremio', 'show', 'und');
    expect(store.subtitleChoice('stremio', 'show'), 'pt');
    await store.setSubtitleChoice('stremio', 'show', '');
    expect(store.subtitleChoice('stremio', 'show'), isNull);
  });

  test('all players respect incognito when saving subtitle choices', () async {
    final store = TitlePrefsStore();
    await store.setSubtitleChoice('stremio', 'show', 'en');
    IncognitoMode.notifier.value = true;
    try {
      await store.setSubtitleChoice('stremio', 'show', 'off');
      expect(store.subtitleChoice('stremio', 'show'), 'en');
    } finally {
      IncognitoMode.notifier.value = false;
    }
  });

  test('remembered subtitle choice is returned per show', () async {
    final store = TitlePrefsStore();
    expect(store.subtitleChoice('anilist', 'show-1'), isNull);

    await store.setSubtitleChoice('anilist', 'show-1', 'hi');
    expect(store.subtitleChoice('anilist', 'show-1'), 'hi');

    // Other shows and sources are unaffected.
    expect(store.subtitleChoice('anilist', 'show-2'), isNull);
    expect(store.subtitleChoice('tmdb', 'show-1'), isNull);

    // 'off' is a real choice, not an empty value.
    await store.setSubtitleChoice('anilist', 'show-1', 'off');
    expect(store.subtitleChoice('anilist', 'show-1'), 'off');
  });
}
