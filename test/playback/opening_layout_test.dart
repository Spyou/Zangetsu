import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  late Directory tempDir;
  late PlaybackPrefs prefs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('opening_layout_test');
    Hive.init(tempDir.path);
    await PlaybackPrefs.init();
    prefs = PlaybackPrefs();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('opening layout preference', () {
    test('defaults to the watch page, even with no saved choice', () {
      expect(prefs.openingLayout, 'watch');
    });

    test('persists an explicit fullscreen choice', () async {
      await prefs.setOpeningLayout('fullscreen');
      expect(prefs.openingLayout, 'fullscreen');
      expect(
        Hive.box(PlaybackPrefs.boxName).get('openingLayout'),
        'fullscreen',
      );
    });

    test('unknown stored values fall back to the watch page', () async {
      await Hive.box(PlaybackPrefs.boxName).put('openingLayout', 'theatre');
      expect(prefs.openingLayout, 'watch');
    });
  });

  group('initial player presentation', () {
    test('TV always opens fullscreen, whatever the preference', () {
      expect(
        initialPresentation(isTv: true, openingLayout: 'watch'),
        PlayerPresentation.fullscreen,
      );
      expect(
        initialPresentation(isTv: true, openingLayout: 'fullscreen'),
        PlayerPresentation.fullscreen,
      );
    });

    test('phone follows the preference', () {
      expect(
        initialPresentation(isTv: false, openingLayout: 'watch'),
        PlayerPresentation.watchPage,
      );
      expect(
        initialPresentation(isTv: false, openingLayout: 'fullscreen'),
        PlayerPresentation.fullscreen,
      );
    });

    test('phone treats unknown values as the watch page', () {
      expect(
        initialPresentation(isTv: false, openingLayout: 'theatre'),
        PlayerPresentation.watchPage,
      );
    });
  });
}
